// Codex (Responses API) <-> OpenCode Zen (Chat Completions API) bridge.
//
// Sits on http://localhost:4001. Point Codex at it via:
//   openai_base_url = "http://localhost:4001/v1"
// and it translates every /v1/responses call into a /v1/chat/completions
// call against OpenCode Zen, translating the streamed SSE response back into
// the Responses API event stream Codex requires.
//
// Configuration (env vars, all optional):
//   CODEX_ZEN_PORT      - listen port            (default 4001)
//   CODEX_ZEN_BASE      - upstream base URL      (default https://opencode.ai/zen/v1)
//   CODEX_ZEN_LOG_DIR   - log + debug files dir  (default ~/.codex)
//   CODEX_ZEN_DEBUG_FILES - set to "1" to write last-raw-incoming.json,
//                           last-upstream-body.json and raw-sse-deltas.log
//   OPENCODE_ZEN_API_KEY - API key sent upstream (required)

const http = require('http');
const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { URL } = require('url');

const PORT = parseInt(process.env.CODEX_ZEN_PORT || '4001', 10);
const ZEN_BASE = process.env.CODEX_ZEN_BASE || 'https://opencode.ai/zen/v1';
const API_KEY = process.env.OPENCODE_ZEN_API_KEY || '';
const LOG_DIR = process.env.CODEX_ZEN_LOG_DIR || path.join(os.homedir(), '.codex');
const LOG = path.join(LOG_DIR, 'proxy-debug.log');
const DEBUG_FILES = process.env.CODEX_ZEN_DEBUG_FILES === '1';

fs.mkdirSync(LOG_DIR, { recursive: true });

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG, line + '\n');
}

// Map of flattened tool name -> {namespace, name} for namespace tools the
// app-server advertises (type: "namespace"). Codex expects calls to namespaced
// tools to come back as function_call items with `namespace` + `name` fields,
// NOT as a flat "namespace__tool" name. Populated from each request's tools.
const knownNamespaces = new Map();

function ingestNamespaces(tools) {
  if (!Array.isArray(tools)) return;
  for (const t of tools) {
    if (!t || typeof t !== 'object') continue;
    if (t.type === 'namespace' && t.name && Array.isArray(t.tools)) {
      for (const sub of t.tools) {
        if (sub && sub.name) {
          knownNamespaces.set(`${t.name}__${sub.name}`, { namespace: t.name, name: sub.name, parameters: sub.parameters });
        }
      }
    }
  }
}

// Reverse-map a model-returned flat function name back to {namespace, name}.
// Unknown names pass through unchanged (normal top-level function tools).
function splitNamespaceName(flatName) {
  if (typeof flatName !== 'string') return { name: flatName };
  const info = knownNamespaces.get(flatName);
  if (!info) return { name: flatName };
  return { namespace: info.namespace, name: info.name };
}

// Convert Responses API message content (string or array of blocks) to plain string
function contentToString(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map(c => c.text || c.content || (typeof c === 'string' ? c : JSON.stringify(c))).join('');
  }
  if (content && typeof content === 'object') {
    return content.text || content.content || JSON.stringify(content);
  }
  return String(content ?? '');
}

function translateToChatCompletions(responsesBody) {
  const { model, input, instructions, tools, temperature, max_output_tokens } = responsesBody;

  const messages = [];
  if (instructions) {
    messages.push({ role: 'system', content: instructions });
  }

  if (typeof input === 'string') {
    messages.push({ role: 'user', content: input });
  } else if (Array.isArray(input)) {
    for (const item of input) {
      if (typeof item === 'string') {
        messages.push({ role: 'user', content: item });
      } else if (item.type === 'message') {
        // Codex uses "developer" role which many providers don't support
        const role = item.role === 'developer' ? 'system' : item.role;
        messages.push({ role, content: contentToString(item.content) });
      } else if (item.type === 'function_call') {
        // Assistant tool call from previous turn. The app-server sends
        // namespace tool calls as {namespace, name}; flatten to the
        // "namespace__tool" form the chat-completions upstream learned.
        const flatName = item.namespace ? `${item.namespace}__${item.name}` : item.name;
        messages.push({
          role: 'assistant',
          content: null,
          tool_calls: [{
            id: item.call_id || item.id,
            type: 'function',
            function: { name: flatName, arguments: typeof item.arguments === 'string' ? item.arguments : JSON.stringify(item.arguments) }
          }]
        });
      } else if (item.type === 'function_call_output') {
        messages.push({ role: 'tool', tool_call_id: item.call_id, content: contentToString(item.output) });
      } else if (item.type === 'reasoning') {
        // Skip reasoning items (not supported by chat completions)
        continue;
      }
    }
  }

  const body = { model, messages };
  if (temperature !== undefined) body.temperature = temperature;
  if (max_output_tokens) body.max_tokens = max_output_tokens;
  if (tools) {
    body.tools = [];
    for (const t of tools) {
      if (t.type === 'function') {
        // Chat-completions requires the `function: {...}` wrapper; Codex may
        // send either top-level `name` (Responses format) or nested function.
        body.tools.push({
          type: 'function',
          function: {
            name: t.name || t.function?.name,
            description: t.description || t.function?.description,
            parameters: t.parameters || t.function?.parameters || { type: 'object', properties: {} }
          }
        });
      } else if (t.type === 'namespace' && Array.isArray(t.tools)) {
        // Codex groups MCP server tools into `namespace` tools. Flatten each
        // nested tool into a function tool named `<namespace>__<tool>` so the
        // chat-completions upstream can call it (Codex routes the call back to
        // the MCP server by that name).
        for (const sub of t.tools) {
          if (sub.type === 'function' && sub.name) {
            body.tools.push({
              type: 'function',
              function: { name: `${t.name}__${sub.name}`, description: sub.description, parameters: sub.parameters || { type: 'object', properties: {} } }
            });
          }
        }
      } else if (t.name && !t.function && t.type === 'custom') {
        // Standalone custom tools (rare) -> function format.
        body.tools.push({
          type: 'function',
          function: { name: t.name, description: t.description, parameters: t.parameters || { type: 'object', properties: {} } }
        });
      }
    }
    if (body.tools.length === 0) delete body.tools;
  }
  return body;
}

function translateToResponses(chatResponse, requestId) {
  const choice = chatResponse.choices?.[0];
  if (!choice) {
    return { id: requestId, object: 'response', status: 'completed', output: [] };
  }

  const output = [];
  if (choice.message?.content) {
    output.push({
      type: 'message',
      id: `msg_${Date.now()}`,
      role: 'assistant',
      content: [{ type: 'output_text', text: choice.message.content }]
    });
  }
  if (choice.message?.tool_calls) {
    for (const tc of choice.message.tool_calls) {
      const { namespace, name } = splitNamespaceName(tc.function.name);
      const item = {
        type: 'function_call',
        id: `call_${Date.now()}_${Math.random().toString(36).slice(2)}`,
        call_id: tc.id,
        name,
        arguments: tc.function.arguments
      };
      if (namespace) item.namespace = namespace;
      output.push(item);
    }
  }

  return {
    id: requestId,
    object: 'response',
    status: 'completed',
    model: chatResponse.model,
    output,
    usage: chatResponse.usage ? {
      input_tokens: chatResponse.usage.prompt_tokens,
      output_tokens: chatResponse.usage.completion_tokens
    } : undefined
  };
}

function sseEvent(eventName, data) {
  return `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`;
}
const server = http.createServer((req, res) => {
  log(`>> ${req.method} ${req.url}`);

  if (req.method === 'GET' && (req.url === '/health' || req.url === '/v1/health')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  if (req.method === 'GET' && /\/(v1\/)?models/.test(req.url)) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ object: 'list', data: [{ id: 'big-pickle', object: 'model' }] }));
    return;
  }

  if (req.method === 'POST' && /\/(v1\/)?responses/.test(req.url)) {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const parsed = JSON.parse(body);
        const chatBody = translateToChatCompletions(parsed);
        const requestId = `resp_${Date.now()}`;
        const isStream = !!parsed.stream;

        // Learn namespace/tool splits from the request so response-side flat
        // function_call names (mcp__node_repl__js) can be split back into
        // {namespace: "mcp__node_repl", name: "js"} before returning to Codex.
        ingestNamespaces(parsed.tools);
        if (Array.isArray(parsed.additional_tools)) ingestNamespaces(parsed.additional_tools);

        if (DEBUG_FILES) {
          fs.writeFileSync(path.join(LOG_DIR, 'last-raw-incoming.json'), JSON.stringify({
            toolTypes: (parsed.tools || []).map(t => ({ type: t.type, name: t.name || t.function?.name, keys: Object.keys(t), namespaceTools: t.tools ? t.tools.length : null, sample: t })),
            nTools: (parsed.tools || []).length
          }, null, 2));
          fs.writeFileSync(path.join(LOG_DIR, 'last-upstream-body.json'), JSON.stringify({ ...chatBody, stream: isStream }));
        }
        log(`>> MODEL: ${parsed.model}, stream: ${isStream}, messages: ${chatBody.messages.length}`);

        const url = new URL(`${ZEN_BASE}/chat/completions`);
        const postData = JSON.stringify({ ...chatBody, stream: isStream });

        log(`>> MESSAGES: ${chatBody.messages.length} total`);

        const proxyReq = https.request({
          hostname: url.hostname,
          path: url.pathname,
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(postData),
            'Authorization': `Bearer ${API_KEY}`
          }
        }, proxyRes => {
          if (isStream) {
            // SSE streaming: relay and translate chunks
            res.writeHead(200, {
              'Content-Type': 'text/event-stream',
              'Cache-Control': 'no-cache',
              'Connection': 'keep-alive'
            });

            let buffer = '';
            let msgSent = false;
            let fullText = '';
            let activeItemId = null;
            // Zen sends each tool call with an `index`. Multiple tool calls can
            // arrive in one response, so track per-index state instead of one
            // shared callId/callName/callArgs (which merged calls like
            // `codex_app__load_workspace_dependencies` + `shell_command` into
            // `...dependenciesshell_command`, rejected as unsupported call).
            const toolStates = new Map();

            const sendEvent = (name, data) => {
              res.write(sseEvent(name, data));
            };

            sendEvent('response.created', {
              type: 'response.created', response: { id: requestId, object: 'response', status: 'in_progress', output: [] }
            });

            const sendMessageStart = () => {
              const itemId = `msg_${Date.now()}`;
              sendEvent('response.output_item.added', {
                type: 'response.output_item.added', output_index: 0, item: {
                  id: itemId, type: 'message', role: 'assistant', content: []
                }
              });
              sendEvent('response.content_part.added', {
                type: 'response.content_part.added', item_id: itemId, output_index: 0, content_index: 0, part: {
                  type: 'output_text', text: '', annotations: []
                }
              });
              msgSent = true;
              return itemId;
            };

            const getToolState = (index) => {
              if (!toolStates.has(index)) toolStates.set(index, { id: null, name: '', args: '', started: false });
              return toolStates.get(index);
            };

            const sendToolStart = (st) => {
              st.id = st.id || `call_${Date.now()}_${Math.random().toString(36).slice(2)}`;
              const { namespace, name } = splitNamespaceName(st.name);
              const item = {
                id: st.id, type: 'function_call', call_id: st.id, name, arguments: ''
              };
              if (namespace) item.namespace = namespace;
              sendEvent('response.output_item.added', {
                type: 'response.output_item.added', output_index: st.index, item
              });
              st.started = true;
            };

            const flushEvent = () => {
              while (true) {
                const idx = buffer.indexOf('\n\n');
                if (idx === -1) break;
                const raw = buffer.slice(0, idx);
                buffer = buffer.slice(idx + 2);
                if (!raw.trim()) continue;
                const lines = raw.split('\n');
                let data = '';
                for (const line of lines) {
                  if (line.startsWith('data:')) data += line.slice(5).trim();
                }
                if (!data || data === '[DONE]') continue;
                try {
                  const chunk = JSON.parse(data);
                  const delta = chunk.choices?.[0]?.delta;
                  const finish = chunk.choices?.[0]?.finish_reason;
                  if (!delta) continue;

                  if (delta.content) {
                    if (!msgSent) activeItemId = sendMessageStart();
                    fullText += delta.content;
                    sendEvent('response.output_text.delta', {
                      type: 'response.output_text.delta',
                      item_id: activeItemId, output_index: 0, content_index: 0, delta: delta.content
                    });
                  }
                  if (delta.tool_calls) {
                    if (DEBUG_FILES) {
                      fs.appendFileSync(path.join(LOG_DIR, 'raw-sse-deltas.log'), JSON.stringify({ tc: delta.tool_calls, finish }) + '\n');
                    }
                    for (const tc of delta.tool_calls) {
                      const index = typeof tc.index === 'number' ? tc.index : (tc.index !== undefined ? Number(tc.index) : 0);
                      const st = getToolState(index);
                      st.index = index;
                      if (tc.function?.name) {
                        // Zen resends the full name on every delta; assign once.
                        if (!st.name) {
                          st.name = tc.function.name;
                        }
                        if (!st.id) st.id = tc.id || null;
                      }
                      if (tc.function?.arguments) {
                        if (!st.started) sendToolStart(st);
                        st.args += tc.function.arguments;
                        sendEvent('response.function_call_arguments.delta', {
                          type: 'response.function_call_arguments.delta',
                          item_id: st.id, output_index: st.index, delta: tc.function.arguments
                        });
                      }
                    }
                  }
                } catch (e) {
                  log(`<< SSE PARSE ERROR: ${e.message}`);
                }
              }
            };

            proxyRes.on('data', c => {
              buffer += c.toString('utf8');
              flushEvent();
            });

            proxyRes.on('end', () => {
              flushEvent();
              if (msgSent) {
                sendEvent('response.output_text.done', {
                  type: 'response.output_text.done',
                  item_id: activeItemId, output_index: 0, content_index: 0, text: fullText
                });
                sendEvent('response.content_part.done', {
                  type: 'response.content_part.done', item_id: activeItemId, output_index: 0, content_index: 0, part: {
                    type: 'output_text', text: fullText, annotations: []
                  }
                });
                sendEvent('response.output_item.done', {
                  type: 'response.output_item.done', output_index: 0, item: {
                    id: activeItemId, type: 'message', role: 'assistant', content: [{ type: 'output_text', text: fullText, annotations: [] }]
                  }
                });
              }
              for (const st of toolStates.values()) {
                if (st.started) {
                  sendEvent('response.function_call_arguments.done', {
                    type: 'response.function_call_arguments.done', item_id: st.id, output_index: st.index, arguments: st.args
                  });
                  const { namespace, name } = splitNamespaceName(st.name);
                  const item = {
                    id: st.id, type: 'function_call', call_id: st.id, name, arguments: st.args
                  };
                  if (namespace) item.namespace = namespace;
                  sendEvent('response.output_item.done', {
                    type: 'response.output_item.done', output_index: st.index, item
                  });
                }
              }
              sendEvent('response.completed', {
                type: 'response.completed', response: { id: requestId, object: 'response', status: 'completed', output: [] }
              });
              res.end();
              log(`<< STREAM COMPLETED (text: ${fullText.slice(0, 80)})`);
            });

            proxyReq.on('error', err => {
              log(`<< STREAM REQUEST ERROR: ${err.message}`);
              res.write(sseEvent('response.error', { type: 'response.error', message: err.message }));
              res.end();
            });
          } else {
            // Non-streaming
            let data = '';
            proxyRes.on('data', c => data += c);
            proxyRes.on('end', () => {
              log(`<< UPSTREAM STATUS: ${proxyRes.statusCode}`);
              try {
                const chatResp = JSON.parse(data);
                if (chatResp.error) {
                  log(`<< UPSTREAM ERROR: ${JSON.stringify(chatResp.error)}`);
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: chatResp.error }));
                } else {
                  const responsesResp = translateToResponses(chatResp, requestId);
                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify(responsesResp));
                }
              } catch (e) {
                log(`<< PARSE ERROR: ${e.message}`);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: { message: 'Failed to parse upstream response' } }));
              }
            });
          }
        });

        proxyReq.on('error', err => {
          log(`<< REQUEST ERROR: ${err.message}`);
          res.writeHead(502, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: { message: err.message } }));
        });

        proxyReq.write(postData);
        proxyReq.end();
      } catch (e) {
        log(`<< BAD REQUEST: ${e.message}`);
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'Invalid request body' } }));
      }
    });
    return;
  }

  log(`<< 404 for ${req.method} ${req.url}`);
  res.writeHead(404);
  res.end('Not found');
});

fs.writeFileSync(LOG, '');
server.listen(PORT, () => {
  log(`Proxy listening on http://localhost:${PORT}`);
  log(`Proxying to ${ZEN_BASE}/chat/completions`);
  log(`API key: ${API_KEY ? 'set (' + API_KEY.slice(0,8) + '...)' : 'NOT SET'}`);
});

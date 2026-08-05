# codex-zen-proxy

Run the **OpenAI Codex CLI / desktop app** on **OpenCode Zen** models (including free ones like `big-pickle`, `mimo-v2.5-free`, `deepseek-v4-flash-free`) through a tiny local translation proxy.

Codex speaks the OpenAI **Responses API**; OpenCode Zen exposes a **Chat Completions** API. This repo contains a ~460-line Node.js proxy that bridges the two on `localhost:4001`, plus a one-command PowerShell installer that recreates the entire working setup.

## Get your OpenCode Zen API key (tutorial)

The installer walks you through this interactively, but here's the whole flow so you know what to expect.

1. **Open the sign-in page**: <https://opencode.ai/auth> (or go to <https://opencode.ai> and click **Zen** → **Get started**).
2. **Sign in** with **GitHub** or **Google**.
3. **Add billing details**: Zen is pay-as-you-go — top up a balance (e.g. $20) with a card, no subscription. It bills per request, zero markup.
4. **Create a key**: in your Zen dashboard go to **API keys** → **Create API key**. Give it a name like `codex-zen-proxy`.
5. **Copy the key** — it starts with `sk-` and looks like `sk-xxxxxxxxxxxxxxxx...`.
6. **Paste it** into the installer when prompted (your input is masked). It is saved only to your Windows **User** environment variable `OPENCODE_ZEN_API_KEY` on this machine.

> Tip: you can also supply the key non-interactively with `-ApiKey sk-xxxx` so the script never asks.

## Setup (one command)

Prerequisites: Windows, PowerShell, [Node.js](https://nodejs.org) >= 16, and an [OpenCode Zen](https://opencode.ai) API key (see above).

```powershell
powershell -Command "$f = Join-Path $env:TEMP setup.ps1; irm 'https://raw.githubusercontent.com/marceli1404/codex-zen-proxy/main/setup.ps1' -OutFile $f; & $f"
```

Or, from a clone:

```powershell
git clone https://github.com/marceli1404/codex-zen-proxy && cd codex-zen-proxy
powershell -ExecutionPolicy Bypass -File setup.ps1
```

The installer is interactive and guided — it shows a step-by-step progress with colored status, a **masked API-key input section** (with a shortcut that opens the key page for you), and a numbered **model picker**. Skip any prompt by passing options up front:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1 -ApiKey sk-xxxx -Model big-pickle
```

What `setup.ps1` does:

1. Checks Node.js.
2. Installs `responses-proxy.js`, `start-proxy.ps1`, and `model-catalog.json` into `%USERPROFILE%\.codex` (respects `CODEX_HOME`).
3. Shows the **API key section**: reuses your saved key if present, or guides you through getting one and prompts with masked input; saves it to the Windows **User** environment.
4. Lets you pick a **model** (numbered menu) and writes it to `config.toml`.
5. Auto-detects the Codex `node_repl.exe` runtime (Computer Use / MCP plugins) and wires it up.
6. Backs up any existing `config.toml` and generates a fresh one pointing Codex at `http://localhost:4001/v1`.
7. (Re)starts the proxy and health-checks `http://localhost:4001/health`.
8. Shows your **free quota today** as two progress bars (requests + tokens), both in the CLI and in the GUI installer.

Then **fully quit and restart** the Codex desktop app, or test the CLI immediately:

```powershell
codex exec -c model=mimo-v2.5-free -c model_provider=opencode-zen "say hello"
```

Switch models by editing `model` in `%USERPROFILE%\.codex\config.toml` (free models: `big-pickle`, `mimo-v2.5-free`, `deepseek-v4-flash-free`, `ling-3.0-flash-free`, `nemotron-3-ultra-free`, `north-mini-code-free`, `laguna-s-2.1-free`).

## How it works

```mermaid
flowchart LR
    U[User] -->|chat| D[Codex Desktop app / CLI]
    D -->|Responses API<br/>POST /v1/responses| AS[app-server codex.exe<br/>stdio transport]

    subgraph Local bridge
        P[responses-proxy.js<br/>:4001]
        N[node_repl.exe<br/>MCP server - Computer Use / plugins]
        C[config.toml<br/>model + provider]
    end

    AS -->|"Responses API over HTTP<br/>http://localhost:4001/v1"| P
    AS -. MCP tools advertised<br/>type:namespace .-> N

    P -->|"Chat Completions API<br/>POST /v1/chat/completions (stream)"| Z[OpenCode Zen<br/>https://opencode.ai/zen/v1]

    Z -->|"SSE stream<br/>chat.completion.chunk"| P
    P -->|"SSE stream<br/>response.created ... response.completed"| AS
    P -->|model_catalog_json + provider config| C
    C -->|"model = mimo-v2.5-free"| AS

    style P fill:#1b1f3b,color:#fff
    style Z fill:#0e3a2f,color:#fff
```

The proxy performs three critical translations:

| Direction | Problem | Fix |
|-----------|---------|-----|
| **Outbound tools** | Codex sends MCP servers as `type:"namespace"` tools (`mcp__node_repl` containing `js`, ...) which the upstream Chat Completions API can't represent | Flattened to `<namespace>__<tool>` function tools (e.g. `mcp__node_repl__js`) |
| **Inbound tool calls** | The model returns the flat name, but Codex's router rejects `mcp__node_repl__js` as an `unsupported call` — it expects a `function_call` with `namespace` + `name` fields | Reverse-map the flat name back to `{namespace: "mcp__node_repl", name: "js"}` via a `knownNamespaces` table learned from each request |
| **Streaming** | Codex requires a specific Responses SSE event order; Chat Completions sends `chat.completion.chunk` deltas with tool-call `index` fields | Re-emit `response.created` → `response.output_item.added` → `…delta` → `…done` → `response.completed`; track tool calls per-`index` so parallel calls don't merge |

Also handled: `developer` role → `system`, `input_text` blocks → plain strings, `reasoning` items dropped, `function_call`/`function_call_output` history re-mapped into `tool_calls`/`tool` messages, tool-name dedup on repeated SSE deltas.

## Free quota tracking

OpenCode Zen has **no public quota/balance API**, so the proxy measures your usage itself: it counts every relayed request and its input/output tokens, bucketed per UTC day, and persists them to `~/.codex/zen-usage.json` (atomic write, survives restarts). The installer (CLI + GUI) and `push.ps1` display the result as two progress bars.

- Endpoint: `GET http://localhost:4001/v1/usage` → `{ day, requests, totalTokens, models: {...}, limits: { requests, tokens } }`.
- Daily limits default to `200` requests and `500000` tokens (community-observed free-tier numbers) and reset at `00:00 UTC`.
- Tune the limits with env vars `CODEX_ZEN_REQ_LIMIT` / `CODEX_ZEN_TOKEN_LIMIT`.
- Streaming usage is captured by enabling `stream_options.include_usage` upstream and reading the final chunk.

## Files

| File | Purpose |
|------|---------|
| `responses-proxy.js` | The bridge (Responses API in, Chat Completions SSE out, reverse-translated). Config via env vars: `CODEX_ZEN_PORT` (4001), `CODEX_ZEN_BASE`, `CODEX_ZEN_LOG_DIR` (`~/.codex`), `CODEX_ZEN_DEBUG_FILES=1`, `OPENCODE_ZEN_API_KEY`, `CODEX_ZEN_REQ_LIMIT`, `CODEX_ZEN_TOKEN_LIMIT` |
| `setup.ps1` | One-command installer described above |
| `start-proxy.ps1` | Manually launch the proxy (reads the API key from the User environment) |
| `model-catalog.json` | Minimal Codex model catalog exposing the 7 free Zen models |
| `push.ps1` | Show today's free quota bar, then commit + push this repo |

## Troubleshooting

- **Proxy won't start / health check fails** — read `%USERPROFILE%\.codex\proxy-debug.log`. Check the API key is present: `[Environment]::GetEnvironmentVariable('OPENCODE_ZEN_API_KEY','User')`.
- **Desktop picker doesn't list the free models** — a known upstream client-side allowlist filter strips non-ChatGPT-account models (openai/codex #19694, #32119, #32049, #10867). Not patchable via config; the CLI path works, and setting `model` directly in `config.toml` still routes correctly ("Custom" provider).
- **`js_repl = false` reappears in config.toml** — the app-server rewrites `[features]` from its own state on startup (upstream #28481). Ignore it; node_repl is still advertised as a namespace tool in current builds.
- **`unsupported call: mcp__node_repl__js`** — this was the main bug this proxy fixes. If it reappears, enable `CODEX_ZEN_DEBUG_FILES=1`, reproduce, and check `raw-sse-deltas.log` for the flat tool name, then confirm the `output_item.done` event carries `namespace`.

## Background

Built and battle-tested against OpenAI Codex build `26.730.8199.0` on Windows 11. The desktop app's `app.asar` is write-protected by the MSIX `bindflt` driver, so this proxy is the clean, update-proof integration point: it sits between Codex and the upstream, requiring no app patching. The desktop auto-updates, and the proxy keeps working.

The namespace-tool issue this solves is tracked upstream as openai/codex #31354, #23186, and #24297; the community `codex-ollama-proxy` project inspired the split mapping.

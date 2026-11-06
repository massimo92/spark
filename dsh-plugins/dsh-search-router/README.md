# dsh-search-router

**English** · [中文](README.zh.md)

A tiny [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness)
plugin: one native `WebSearchProvider` registered into `ctx.web`, forwarding
every `web_search` call to a search backend you choose — with sequential
fallback when one fails. The model keeps seeing the same `web_search` tool; no
new tools, no MCP, no reranking, no caching.

```
DSH Agent → web_search → ctx.web → dsh-search-router → Exa / Tavily / Brave / SearXNG
```

## Supported providers

| Provider | Credential | Endpoint |
| --- | --- | --- |
| **Exa** | `EXA_API_KEY` | `https://api.exa.ai` |
| **Tavily** | `TAVILY_API_KEY` | `https://api.tavily.com` |
| **Brave** | `BRAVE_SEARCH_API_KEY` | `https://api.search.brave.com` |
| **Perplexity** | `PPLX_API_KEY` | `https://api.perplexity.ai` |
| **DeepSeek** | `DEEPSEEK_API_KEY` | `https://api.deepseek.com/anthropic/v1` |
| **SearXNG** | none (self-hosted) | `SEARXNG_BASE_URL` |
| **DuckDuckGo** | none | — |

SearXNG keeps the router fully self-hostable — no commercial API needed. The
instance must enable the `json` output format (`search.formats` in its
`settings.yml`). DuckDuckGo is keyless, so a zero-configuration deployment
still serves web searches out of the box. Provider endpoints (and the
Perplexity/DeepSeek model) can be overridden per provider (see the full
schema below).

## Install

```bash
dsh plugin --profile web add github:XGrin/dsh-search-router
dsh web
```

Or clone and link locally (for development):

```bash
git clone https://github.com/XGrin/dsh-search-router.git
dsh plugin --profile web add link:/path/to/dsh-search-router
```

The composition patch points the web seam at the router, disables the built-in
DeepSeek search provider, and re-enables the `web_search` tool in the web
profile. Uninstall (`dsh plugin --profile web remove dsh-search-router`)
restores the original composition.

## Configure

Two ways, targeting the same knobs — the GUI wins per field, and a GUI reset
re-inherits the composition value. With zero configuration the router
auto-detects every provider whose key or endpoint is ambient, in canonical
order: exa → tavily → brave → perplexity → deepseek → searxng → duckduckgo.

### In the app

**Settings → Plugins → Plugin configuration** shows a "Search router" card:
one row per active provider, numbered by fallback priority and **draggable to
reorder** (also keyboard-reorderable), an inline editor per provider, an
add-provider flow, and an Advanced fold (timeout, empty-results policy). Every
change applies live — no restart.

API keys entered here persist in the settings document as secrets and
**override** the environment variables; clearing a stored key falls back to
`EXA_API_KEY` / `TAVILY_API_KEY` / `BRAVE_SEARCH_API_KEY`.

### In the composition

The profile's own patch layer — `$DSH_HOME/profiles/web/cordis.patch.yml`
(create it if absent). A patch replaces the row's whole `config`, so state the
complete block. Two examples:

```yaml
# Tavily, falling back to a self-hosted SearXNG
- id: search-router
  config:
    order: [tavily, searxng]
    providers:
      tavily: { apiKeyEnv: TAVILY_API_KEY }
      searxng: { baseUrl: https://search.example.com }

# SearXNG only — no commercial keys anywhere
- id: search-router
  config:
    provider: searxng
    providers:
      searxng: { baseUrl: http://127.0.0.1:8888 }
```

Full schema:

```yaml
- id: search-router
  config:
    provider: exa                  # single-provider mode (XOR with order)
    order: [exa, tavily, searxng]  # fallback-chain mode
    timeoutMs: 10000               # per-provider timeout (default 10000)
    emptyResultsFallback: true     # 0-result success counts as failure (default true)
    providers:
      exa:        { apiKey: …, apiKeyEnv: EXA_API_KEY, baseURL: … }
      tavily:     { apiKey: …, apiKeyEnv: TAVILY_API_KEY, baseURL: … }
      brave:      { apiKey: …, apiKeyEnv: BRAVE_SEARCH_API_KEY, baseURL: … }
      perplexity: { apiKey: …, apiKeyEnv: PPLX_API_KEY, baseURL: …, model: sonar }
      deepseek:   { apiKey: …, apiKeyEnv: DEEPSEEK_API_KEY, baseURL: …, model: deepseek-v4-flash }
      searxng:    { baseUrl: …, baseUrlEnv: SEARXNG_BASE_URL }
      duckduckgo: { baseURL: … }
  ```

Prefer `apiKeyEnv` over a literal `apiKey` in files you might commit.

## Fallback

A provider counts as failed on network errors, timeouts, any non-2xx status,
unparseable responses — and by default on empty results
(`emptyResultsFallback: false` to change). The router walks the chain in order
and returns the first success; the model never sees the earlier failures. If
every provider fails, `web_search` throws one aggregated, key-free error:

```
search-router: all configured search providers failed:
- exa: HTTP 429
- tavily: timeout after 10000ms
- searxng: HTTP 503
```

## Development

```bash
node test/integration.mjs /path/to/a/dsh/installation/node_modules   # router vs. the real seam, mocked providers
node test/client-smoke.mjs                                          # browser bundle, the way the shell loads it
```

MIT.

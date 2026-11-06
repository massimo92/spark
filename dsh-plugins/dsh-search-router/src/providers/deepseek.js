/**
 * DeepSeek adapter — `POST {baseURL}/messages` (Anthropic-compatible) with
 * the native `web_search_20250305` server tool. Wire format mirrors the
 * upstream `@deepseek-ai/dsh-web-search-deepseek` provider, self-contained
 * here so the router treats DeepSeek exactly like every other backend: one
 * credential reference (`DEEPSEEK_API_KEY`), optional stored-key override,
 * per-provider timeout, and automatic skip when no key is configured. Each
 * search costs a model turn; results come back as structured blocks.
 *
 * Snippets: `web_search_result` items carry url/title/page_age but no inline
 * excerpt — the excerpt lives in a separate `text` block's `citations[]`,
 * keyed by url (first occurrence wins).
 */
import { httpJSON, normalizeSources, joinURL } from "../lib.js";

/** Default endpoint: DeepSeek's Anthropic-compatible API (`/messages` appended). */
const DEFAULT_BASE_URL = "https://api.deepseek.com/anthropic/v1";
/** Default Anthropic-format model name. */
const DEFAULT_MODEL = "deepseek-v4-flash";
/** Default `anthropic-version` header value. */
const API_VERSION = "2023-06-01";

/** The deepseek provider descriptor (id from its file name). */
export default {
  id: "deepseek",
  defaultApiKeyEnv: "DEEPSEEK_API_KEY",
  defaultBaseURL: DEFAULT_BASE_URL,
  defaultModel: DEFAULT_MODEL,
  meta: { label: "DeepSeek", sort: 5 },

  async search(request, armed, options) {
    const json = await httpJSON(joinURL(armed.baseURL, "messages").href, {
      method: "POST",
      headers: {
        "x-api-key": armed.apiKey,
        authorization: `Bearer ${armed.apiKey}`,
        "anthropic-version": API_VERSION,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({
        model: armed.model ?? DEFAULT_MODEL,
        max_tokens: 4096,
        messages: [{
          role: "user",
          content: [{ type: "text", text: `Perform a web search for the query: ${request.query}` }],
        }],
        tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
      }),
    }, options);
    return normalizeSources(flatResults(json), request.maxResults);
  },
};

/**
 * Project one Messages response onto raw result items: walk
 * `web_search_tool_result` blocks for url/title/page_age, joined with any
 * citation excerpts under the same url.
 *
 * @param {object} response - the parsed Messages response body.
 * @returns {{ url: string, title?: string, snippet?: string, page_age?: string }[]} raw items.
 */
function flatResults(response) {
  const blocks = Array.isArray(response?.content) ? response.content : [];
  const snippets = new Map();
  for (const block of blocks) {
    if (block.type !== "text") continue;
    for (const cite of block.citations ?? []) {
      if (typeof cite.url === "string" && cite.url.length > 0 && typeof cite.cited_text === "string" && cite.cited_text.length > 0 && !snippets.has(cite.url)) {
        snippets.set(cite.url, cite.cited_text);
      }
    }
  }
  const items = [];
  for (const block of blocks) {
    if (block.type !== "web_search_tool_result") continue;
    for (const item of block.content ?? []) {
      if (item.type !== "web_search_result" || typeof item.url !== "string" || item.url.length === 0) continue;
      const snippet = snippets.get(item.url);
      items.push({
        url: item.url,
        ...(typeof item.title === "string" && item.title.length > 0 ? { title: item.title } : {}),
        ...(snippet !== undefined ? { snippet } : {}),
        ...(typeof item.page_age === "string" && item.page_age.length > 0 ? { page_age: item.page_age } : {}),
      });
    }
  }
  return items;
}

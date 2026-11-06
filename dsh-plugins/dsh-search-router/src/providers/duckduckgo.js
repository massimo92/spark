/**
 * DuckDuckGo adapter — `POST {baseURL}/html/` (form-encoded `q`), the
 * keyless HTML endpoint SearXNG's own DDG engine also uses. There is no
 * official DDG web-search API: the Instant Answer JSON endpoint returns
 * near-zero usable results (verified empirically), so this adapter parses
 * the HTML SERP leniently — `result__a` anchors for url/title,
 * `result__snippet` anchors for snippets — and treats an unparseable page
 * as a normal provider failure the router falls through on. Redirect-wrapped
 * links (`duckduckgo.com/l/?uddg=…`) are unwrapped to their target.
 */
import { httpText, joinURL, normalizeSources, USER_AGENT } from "../lib.js";

/** The duckduckgo provider descriptor (id from its file name). */
export default {
  id: "duckduckgo",
  defaultApiKeyEnv: undefined,
  defaultBaseURL: "https://html.duckduckgo.com",
  meta: { label: "DuckDuckGo", sort: 7, keyless: true },

  async search(request, armed, options) {
    const body = new URLSearchParams({ q: request.query });
    const html = await httpText(joinURL(armed.baseURL, "html/").href, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        accept: "text/html",
        "user-agent": USER_AGENT,
      },
      body: body.toString(),
    }, options);
    return normalizeSources(parseSERP(html), request.maxResults);
  },
};

/**
 * Extract result items from one lite/HTML SERP page. Returns raw-shaped
 * items (`url` / `title` / `snippet`) for the shared normalizer; an empty
 * array means "nothing parsed" and becomes a 0-results provider outcome.
 *
 * @param {string} html - the response body.
 * @returns {{ url: string, title: string, snippet?: string }[]} raw items.
 */
function parseSERP(html) {
  if (typeof html !== "string") return [];
  const anchors = [...html.matchAll(/class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gu)];
  const snippets = [...html.matchAll(/class="result__snippet"[^>]*>([\s\S]*?)<\/a>/gu)].map((match) => strip(match[1]));
  return anchors.map((match, index) => ({
    url: unwrap(match[1]),
    title: strip(match[2]),
    ...(snippets[index] !== undefined && snippets[index] !== "" ? { snippet: snippets[index] } : {}),
  }));
}

/**
 * Unwrap DDG redirect links to the real target; leave direct URLs
 * untouched. A malformed `uddg` payload falls back to the wrapped href —
 * one bad link never poisons the rest of the page.
 */
function unwrap(href) {
  const decoded = href.replace(/&amp;/gu, "&");
  const target = /duckduckgo\.com\/l\/\?[^>]*uddg=([^&]+)/iu.exec(decoded);
  if (target === null) return decoded;
  try {
    return decodeURIComponent(target[1]);
  } catch {
    return decoded;
  }
}

/** Collapse whitespace and drop any markup from a SERP fragment. */
function strip(text) {
  return text.replace(/<\/?[a-z][^>]*>/giu, "").replace(/\s+/gu, " ").trim();
}

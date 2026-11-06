/**
 * Brave Search adapter — `GET {baseURL}/res/v1/web/search?q=…&count=…`.
 *
 * Docs: https://api-dashboard.search.brave.com/app/documentation/web-search-query.
 * The key travels in the `X-Subscription-Token` header. Results live under
 * `web.results` and carry `title` / `url` / `description` ( Brave bold-marks
 * queries with <b> tags — stripped here) and sometimes `page_age` / `age`.
 */
import { httpJSON, normalizeSources, clampCount, joinURL, USER_AGENT } from "../lib.js";

/** The brave provider descriptor (id from its file name). */
export default {
  id: "brave",
  defaultApiKeyEnv: "BRAVE_SEARCH_API_KEY",
  defaultBaseURL: "https://api.search.brave.com",
  meta: { label: "Brave", sort: 3 },

  async search(request, armed, options) {
    const url = joinURL(armed.baseURL, "res/v1/web/search");
    url.searchParams.set("q", request.query);
    url.searchParams.set("count", String(clampCount(request.maxResults, 8, 20)));
    const json = await httpJSON(url.href, {
      method: "GET",
      headers: {
        "x-subscription-token": armed.apiKey,
        accept: "application/json",
        "user-agent": USER_AGENT,
      },
    }, options);
    return normalizeSources(json?.web?.results, request.maxResults);
  },
};

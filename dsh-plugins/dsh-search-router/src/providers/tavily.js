/**
 * Tavily adapter — `POST {baseURL}/search`.
 *
 * Docs: https://docs.tavily.com/api-reference/endpoint/search. The key
 * travels as `Authorization: Bearer …`; `max_results` is Tavily's native
 * count control. Response items carry `title` / `url` / `content` (mapped to
 * `snippet`) and sometimes `published_date`. The API can also synthesize an
 * answer (`include_answer`) — deliberately not requested in the MVP.
 */
import { httpJSON, normalizeSources, clampCount, joinURL } from "../lib.js";

/** The tavily provider descriptor (id from its file name). */
export default {
  id: "tavily",
  defaultApiKeyEnv: "TAVILY_API_KEY",
  defaultBaseURL: "https://api.tavily.com",
  meta: { label: "Tavily", sort: 2 },

  async search(request, armed, options) {
    const body = {
      query: request.query,
      max_results: clampCount(request.maxResults, 8, 20),
      search_depth: "basic",
    };
    const json = await httpJSON(joinURL(armed.baseURL, "search").href, {
      method: "POST",
      headers: {
        authorization: `Bearer ${armed.apiKey}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify(body),
    }, options);
    return normalizeSources(json?.results, request.maxResults);
  },
};

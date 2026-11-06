/**
 * Exa adapter — `POST {baseURL}/search`.
 *
 * Docs: https://docs.exa.ai/reference/search. The key travels in the
 * `x-api-key` header; `numResults` is Exa's native result-count control and
 * the seam re-truncates on the way back regardless. Response items carry
 * `title` / `url` / `publishedDate` (ISO) and, when contents were requested,
 * `text` — mapped onto `snippet` by the shared normalizer. No contents are
 * requested by default: MVP keeps the request to the plain search call.
 */
import { httpJSON, normalizeSources, clampCount, joinURL } from "../lib.js";

/** The exa provider descriptor (id from its file name). */
export default {
  id: "exa",
  defaultApiKeyEnv: "EXA_API_KEY",
  defaultBaseURL: "https://api.exa.ai",
  meta: { label: "Exa", sort: 1 },

  async search(request, armed, options) {
    const body = {
      query: request.query,
      numResults: clampCount(request.maxResults, 8, 100),
    };
    const json = await httpJSON(joinURL(armed.baseURL, "search").href, {
      method: "POST",
      headers: {
        "x-api-key": armed.apiKey,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify(body),
    }, options);
    return normalizeSources(json?.results, request.maxResults);
  },
};

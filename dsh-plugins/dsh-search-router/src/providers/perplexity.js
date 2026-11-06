/**
 * Perplexity adapter — `POST {baseURL}/search`.
 *
 * Docs: https://docs.perplexity.ai/api-reference/search. The key travels as
 * `Authorization: Bearer …`. Response `results[]` carries `title` / `url` /
 * `date` / `text` (mapped to `snippet`). The API can also synthesize an
 * answer; not read here — sources are the router's vocabulary. Result count
 * is not requested: the shared normalizer caps at the seam's bound.
 */
import { httpJSON, normalizeSources, joinURL } from "../lib.js";

/** Default search model. */
const DEFAULT_MODEL = "sonar";

/** The perplexity provider descriptor (id from its file name). */
export default {
  id: "perplexity",
  defaultApiKeyEnv: "PPLX_API_KEY",
  defaultBaseURL: "https://api.perplexity.ai",
  defaultModel: DEFAULT_MODEL,
  meta: { label: "Perplexity", sort: 4 },

  async search(request, armed, options) {
    const json = await httpJSON(joinURL(armed.baseURL, "search").href, {
      method: "POST",
      headers: {
        authorization: `Bearer ${armed.apiKey}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({
        model: armed.model ?? DEFAULT_MODEL,
        query: request.query,
      }),
    }, options);
    return normalizeSources(json?.results, request.maxResults);
  },
};

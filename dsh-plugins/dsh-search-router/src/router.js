/**
 * The search router: one DSH `WebSearchProvider` (id `search-router`) that
 * forwards each `web_search` call to a user-configured chain of search
 * backends, falling through to the next backend on failure.
 *
 * Backend contract (one object per src/providers/*.js):
 *   {
 *     id: string,                       // one id per file in src/providers/
 *     defaultApiKeyEnv?: string,        // credential ref / env var name
 *     defaultBaseURL?: string,          // API origin (searxng has none — user-supplied)
 *     async search(request, armed, options): Promise<{ sources, content? }>
 *   }
 * `armed` is `{ apiKey?: string, baseURL: string }` resolved by the router
 * right before the call; `options` is `{ signal, timeoutMs }`. A backend
 * reports failure by throwing — the router owns every fallback decision.
 *
 * Selection modes (from the plugin config):
 *   - `order: [exa, tavily, searxng]` — sequential fallback chain;
 *   - `provider: exa` — that one backend, no fallback;
 *   - neither — every backend whose credential/endpoint is locally
 *     discoverable, in canonical order (each provider's `meta.sort`).
 *
 * A backend counts as failed on network errors, timeouts, HTTP 401/403/429/
 * 5xx (any non-2xx in fact), unparseable responses — and, by default, on
 * empty result lists. When every backend yields an empty-but-successful
 * response, the (truthful) empty result is returned instead of an error.
 */
import { readdirSync } from "node:fs";
import { DEFAULT_TIMEOUT_MS, callerAborted, isCallerAborted } from "./lib.js";
import { loadProvider } from "./providers/__registry.js";
/**
 * The backends this router knows, discovered from src/providers/*.js: each
 * file's default export is one provider descriptor (see below) and its file
 * name is its id, so ADDING A PROVIDER IS DROPPING IN ONE FILE — nothing
 * else changes. Canonical order is each provider's `meta.sort` (then id), so
 * the router's auto-chain, the settings schema, and the settings card all
 * present one priority order; a provider's `meta` (name, kind of credential,
 * endpoint field, sort hint) drives the settings schema and the card, so
 * neither carries a provider list.
 *
 * A descriptor looks like:
 *   export default {
 *     id, defaultApiKeyEnv?, defaultBaseURL?, defaultModel?,
 *     meta: { label, keyless?, baseUrlEnv?, baseUrlLabel?, envHint? },
 *     async search(request, armed, options) { … }   // throw = failed
 *   }
 */
export const BACKENDS = discoverBackends();

/** Load every provider module in src/providers, indexed by id in canonical order. */
function discoverBackends() {
  const entries = [];
  for (const file of readdirSync(new URL("./providers/", import.meta.url)).filter((name) => name.endsWith(".js") && !name.startsWith("_"))) {
    const id = file.slice(0, -3);
    entries.push([id, loadProviderSync(id)]);
  }
  entries.sort(([, a], [, b]) => (a.meta?.sort ?? 99) - (b.meta?.sort ?? 99) || a.id.localeCompare(b.id));
  return Object.fromEntries(entries);
}

/** Load one provider module, validating its shape loudly. */
function loadProviderSync(id) {
  const backend = loadProvider(id);
  if (backend === undefined) {
    throw new Error(`search-router: src/providers/${id}.js is missing from src/providers/__registry.js — run \`npm run providers\` to regenerate the registry`);
  }
  if (typeof backend !== "object" || backend.id !== id) {
    throw new Error(`search-router: src/providers/${id}.js must export a provider whose id is "${id}"`);
  }
  return backend;
}

/** The id the router registers under in the DSH web seam. */
export const SEARCH_ROUTER_PROVIDER_ID = "search-router";

/** Default result count passed to providers that support a count control. */
const DEFAULT_MAX_RESULTS = 8;

/**
 * Validate and normalize the plugin config. Throws descriptive errors —
 * a typo in the composition should fail loudly at load, never silently
 * no-op. Shape:
 *
 *   {
 *     provider?: string,                 // one backend id, no fallback
 *     order?: string[],                  // fallback chain of backend ids
 *     timeoutMs?: number,                 // per-provider, default 10000
 *     emptyResultsFallback?: boolean,     // default true
 *     providers?: { [id]: { apiKey?, apiKeyEnv?, baseURL? | baseUrl?, baseUrlEnv?, model? } },
 *   }
 *
 * @param {unknown} raw - the row config cordis passed to apply().
 * @returns {object} the normalized config.
 */
export function parseConfig(raw) {
  const config = raw ?? {};
  if (typeof config !== "object" || Array.isArray(config)) {
    throw new Error("search-router: config must be an object");
  }
  const { provider, order, timeoutMs, emptyResultsFallback, providers, ...unknown } = config;
  for (const key of Object.keys(unknown)) {
    throw new Error(`search-router: unknown config key "${key}" (expected provider, order, timeoutMs, emptyResultsFallback, providers)`);
  }
  if (provider !== undefined && !isBackendId(provider)) {
    throw new Error(`search-router: unknown provider "${provider}" (expected ${ids().join(", ")})`);
  }
  if (order !== undefined) {
    if (!Array.isArray(order) || order.length === 0 || order.some((id) => !isBackendId(id))) {
      throw new Error(`search-router: order must be a non-empty array of provider ids (expected ${ids().join(", ")})`);
    }
  }
  if (provider !== undefined && order !== undefined) {
    throw new Error("search-router: configure either provider (single) or order (fallback chain), not both");
  }
  if (timeoutMs !== undefined && (typeof timeoutMs !== "number" || !Number.isInteger(timeoutMs) || timeoutMs < 100)) {
    throw new Error("search-router: timeoutMs must be an integer >= 100 (milliseconds)");
  }
  if (emptyResultsFallback !== undefined && typeof emptyResultsFallback !== "boolean") {
    throw new Error("search-router: emptyResultsFallback must be a boolean");
  }
  return {
    provider,
    order: order === undefined ? undefined : [...new Set(order)],
    timeoutMs: timeoutMs ?? DEFAULT_TIMEOUT_MS,
    emptyResultsFallback: emptyResultsFallback ?? true,
    providers: parseProviderSections(providers),
  };
}

/** Validate the per-provider sections; unknown ids and keys are rejected. */
function parseProviderSections(providers) {
  if (providers === undefined) return {};
  if (typeof providers !== "object" || Array.isArray(providers)) {
    throw new Error("search-router: providers must be an object keyed by provider id");
  }
  const parsed = {};
  for (const [id, section] of Object.entries(providers)) {
    if (!isBackendId(id)) {
      throw new Error(`search-router: unknown provider section "${id}" (expected ${ids().join(", ")})`);
    }
    if (typeof section !== "object" || section === null || Array.isArray(section)) {
      throw new Error(`search-router: providers.${id} must be an object`);
    }
    const { apiKey, apiKeyEnv, baseURL, baseUrl, baseUrlEnv, model, ...unknown } = section;
    for (const key of Object.keys(unknown)) {
      throw new Error(`search-router: unknown key "${key}" in providers.${id}`);
    }
    const parsedModel = optionalString(model, `providers.${id}.model`);
    if (parsedModel !== undefined && BACKENDS[id].defaultModel === undefined) {
      throw new Error(`search-router: providers.${id}.model is not configurable for "${id}"`);
    }
    parsed[id] = {
      apiKey: optionalString(apiKey, `providers.${id}.apiKey`),
      apiKeyEnv: optionalString(apiKeyEnv, `providers.${id}.apiKeyEnv`),
      baseURL: normalizeOptionalURL(baseURL ?? baseUrl, `providers.${id}.baseURL`),
      baseUrlEnv: optionalString(baseUrlEnv, `providers.${id}.baseUrlEnv`),
      ...(parsedModel !== undefined ? { model: parsedModel } : {}),
    };
  }
  return parsed;
}

/** The registered backend ids in canonical order. */
function ids() {
  return Object.keys(BACKENDS);
}

/** True for a known backend id. */
function isBackendId(id) {
  return typeof id === "string" && id in BACKENDS;
}

/** A non-empty string or undefined; anything else throws. */
function optionalString(value, field) {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || value.length === 0) throw new Error(`search-router: ${field} must be a non-empty string`);
  return value;
}

/** An http(s) URL or undefined; anything else throws. */
function normalizeOptionalURL(value, field) {
  const text = optionalString(value, field);
  if (text === undefined) return undefined;
  const url = new URL(text);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`search-router: ${field} must be an http(s) URL`);
  }
  return text.replace(/\/+$/u, "");
}

/**
 * Build the router provider. Credential and endpoint resolution goes through
 * DSH's own planes when present — the credentials service first (it owns the
 * managed store and already ranks env layers), then the launch environment
 * snapshot, then the ambient process env — so keys never live in code and
 * `apiKeyEnv` doubles as the credential reference, exactly like the shipped
 * web-search-deepseek provider.
 *
 * The provider resolves its config through `resolveConfig()` at every
 * search, so settings writes from the Plugins page take effect on the next
 * search with no restart.
 *
 * @param {object} ctx - the plugin context (`web` is injected).
 * @param {() => object} resolveConfig - returns the currently effective
 *   normalized config (composition merged with the settings section).
 * @returns {object} the `search-router` WebSearchProvider.
 */
export function createRouterProvider(ctx, resolveConfig) {
  const log = typeof ctx.logger === "function" ? ctx.logger("dsh-search-router") : ctx.logger;

  /** Resolve one variable through the launch snapshot, then process.env. */
  const ambient = (name) => {
    const value = ctx.get("launchEnvironment")?.get(name)?.value ?? process.env[name];
    return typeof value === "string" && value.length > 0 ? value : undefined;
  };

  /** Resolve one secret: credentials service over ambient environment. */
  const resolveSecret = async (name) => {
    const credentials = ctx.get("credentials");
    if (credentials !== undefined) {
      try {
        const resolved = await credentials.resolve(name);
        if (resolved?.value !== undefined && resolved.value.length > 0) return resolved.value;
      } catch {
        /* fall through to the ambient environment */
      }
    }
    return ambient(name);
  };

  /** The backend chain per the CURRENT config: explicit routing, else auto-detection. */
  const chain = async () => {
    const config = resolveConfig();
    if (config.order !== undefined) return config.order;
    if (config.provider !== undefined) return [config.provider];
    // Auto-detection resolves each keyed provider's credential through the
    // same plane arm() uses, so a key held only in the managed credentials
    // store drives detection exactly like an ambient one — the settings card
    // (which reads that store through the credentials domain) agrees.
    const detected = [];
    for (const id of ids()) {
      const backend = BACKENDS[id];
      const section = config.providers[id] ?? {};
      if (backend.defaultApiKeyEnv === undefined) {
        if (keylessReady(backend, section)) detected.push(id);
      } else if (section.apiKey !== undefined || (await resolveSecret(section.apiKeyEnv ?? backend.defaultApiKeyEnv)) !== undefined) {
        detected.push(id);
      }
    }
    return detected;
  };

  /**
   * A keyless provider is detectable when its endpoint resolves: an explicit
   * baseURL, its own `meta.baseUrlEnv` ambient, or its shipped
   * defaultBaseURL (DuckDuckGo needs nothing at all). A keyed provider that
   * carries its own defaultBaseURL needs nothing but its key.
   */
  const keylessReady = (backend, section) =>
    (section.baseURL ?? ambient(section.baseUrlEnv ?? backend.meta?.baseUrlEnv) ?? backend.defaultBaseURL) !== undefined;

  /** Resolve everything one backend needs right before calling it. */
  const arm = async (id) => {
    const section = resolveConfig().providers[id] ?? {};
    const backend = BACKENDS[id];
    const keyed = backend.defaultApiKeyEnv !== undefined;
    const apiKey = keyed ? section.apiKey ?? await resolveSecret(section.apiKeyEnv ?? backend.defaultApiKeyEnv) : undefined;
    const baseURL = keyed
      ? section.baseURL
      : section.baseURL ?? ambient(section.baseUrlEnv ?? backend.meta?.baseUrlEnv);
    return {
      apiKey,
      baseURL: baseURL ?? backend.defaultBaseURL,
      ...(section.model !== undefined ? { model: section.model } : {}),
    };
  };

  /** Every credential/endpoint variable an auto-mode deployment could use. */
  const ambientHints = () => [...new Set(ids().flatMap((id) => {
    const backend = BACKENDS[id];
    const section = resolveConfig().providers[id] ?? {};
    if (backend.defaultApiKeyEnv !== undefined) return [section.apiKeyEnv ?? backend.defaultApiKeyEnv];
    const env = section.baseUrlEnv ?? backend.meta?.baseUrlEnv;
    return env === undefined ? [] : [env];
  }))];

  return {
    id: SEARCH_ROUTER_PROVIDER_ID,

    /**
     * Deliberately optimistic, like the shipped web-search-deepseek
     * provider: a key held only in the managed credentials store cannot be
     * probed synchronously, and a false `false` here is a hard error at the
     * seam (the composition points web.searchProvider at this router). The
     * real verdict — descriptive, naming the variables to export — belongs
     * to search().
     */
    available() {
      return true;
    },

    async search(request, signal) {
      if (signal?.aborted === true) throw callerAborted(signal);
      const ids_ = await chain();
      if (ids_.length === 0) {
        throw new Error(
          "search-router: no search provider is configured — set provider/order in the search-router config, "
          + `store keys on the Plugins settings page, or export ${ambientHints().join(" / ")}`,
        );
      }
      const failures = [];
      let emptiest;
      for (let index = 0; index < ids_.length; index += 1) {
        const id = ids_[index];
        const backend = BACKENDS[id];
        const armed = await arm(id);
        if ((backend.defaultApiKeyEnv !== undefined && armed.apiKey === undefined) || armed.baseURL === undefined) {
          const hint = backend.defaultApiKeyEnv === undefined
            ? `missing endpoint (set providers.${id}.baseUrl, the Plugins settings page, or export ${section0(resolveConfig(), id).baseUrlEnv ?? backend.meta?.baseUrlEnv})`
            : `missing API key (set providers.${id}.apiKey, the Plugins settings page, or export ${section0(resolveConfig(), id).apiKeyEnv ?? backend.defaultApiKeyEnv})`;
          failures.push(`${id}: ${hint}`);
          log?.info?.(`${id}: ${hint} — skipped${next(id, ids_)}`);
          continue;
        }
        if (signal?.aborted === true) throw callerAborted(signal);
        try {
          const result = await backend.search(
            { query: request.query, maxResults: request.maxResults ?? DEFAULT_MAX_RESULTS },
            armed,
            { signal, timeoutMs: resolveConfig().timeoutMs },
          );
          if (result.sources.length === 0 && resolveConfig().emptyResultsFallback) {
            failures.push(`${id}: 0 results`);
            emptiest = result;
            log?.info?.(`${id}: 0 results${next(id, ids_)}`);
            continue;
          }
          return {
            sources: result.sources,
            truncated: result.truncated ?? false,
            ...result.content !== undefined ? { content: result.content } : {},
          };
        } catch (error) {
          if (isCallerAborted(error) || signal?.aborted === true) throw callerAborted(signal);
          failures.push(`${id}: ${error instanceof Error ? error.message : String(error)}`);
          log?.info?.(`${id} failed: ${error instanceof Error ? error.message : String(error)}${next(id, ids_)}`);
        }
      }
      if (emptiest !== undefined) return { sources: emptiest.sources, truncated: emptiest.truncated ?? false };
      throw new Error(`search-router: all configured search providers failed:\n${failures.map((f) => `- ${f}`).join("\n")}`);
    },
  };
}

/** The provider section for `id`, or `{}` (kept tiny; used for error hints). */
function section0(config, id) {
  return config.providers[id] ?? {};
}

/** `" — falling back to <next>"` when another backend follows, else `""`. */
function next(id, ids) {
  const following = ids[ids.indexOf(id) + 1];
  return following === undefined ? "" : ` — falling back to ${following}`;
}

/**
 * The settings face of dsh-search-router: the flat schema the Plugins
 * settings page edits, the projection of the composition config into that
 * flat shape, and the merge that folds a resolved settings section back over
 * the composition — so the GUI and the profile's cordis.patch.yml are two
 * layers over one router, with the GUI winning per field.
 *
 * The schema is deliberately flat and scalar: the client settings scope
 * writes one top-level field per operation, so every editable knob is a
 * top-level field. Provider endpoint/key overrides that only a composition
 * author needs (per-provider baseURL literals, nested provider sections)
 * stay in the plugin row config; the GUI covers the knobs a user owns:
 * which provider(s) run, the timeout, the empty-results policy, endpoint
 * fields, and the keyed providers' API keys (stored key overrides persist
 * in the settings document as role('secret') fields; the values themselves
 * never cross the wire).
 */
import z from "@deepseek-ai/schemastery";

/** Settings namespace this plugin serves (== the plugin's short name). */
export const SETTINGS_NS = "search-router";

/**
 * The provider catalog, derived from the router's discovered backends: every
 * field of the settings schema and every shape the card renders comes from a
 * provider's own descriptor (`id`, `defaultApiKeyEnv`, `meta`), so adding a
 * provider file changes nothing here. The catalog closes over the backend
 * index it was built from — no module-level state, so two registrations in
 * one process never cross wires.
 *
 * @param {Record<string, object>} backends - the router's BACKENDS index.
 * @returns the catalog: sorted ids, keyed/keyless splits, and per-id lookups.
 */
export function providerCatalog(backends) {
  const ids = Object.keys(backends).sort((a, b) => (backends[a].meta?.sort ?? 99) - (backends[b].meta?.sort ?? 99) || a.localeCompare(b));
  return {
    ids,
    keyed: ids.filter((id) => backends[id].defaultApiKeyEnv !== undefined),
    keyless: ids.filter((id) => backends[id].defaultApiKeyEnv === undefined),
    envOf: (id) => backends[id].defaultApiKeyEnv,
    labelOf: (id) => backends[id].meta?.label ?? id,
    needsBaseUrl: (id) => backends[id].defaultBaseURL === undefined && backends[id].meta?.keyless !== true,
  };
}

/**
 * Build the settings section schema for one provider catalog. Field
 * semantics (per provider `<id>` from the catalog):
 * - `provider` — single-backend mode ("" = not chosen here);
 * - `order` — fallback-chain mode as a comma/space-separated id list;
 * - `timeoutMs` / `emptyResultsFallback` — router-wide policy;
 * - `<id>ApiKey` — a stored key OVERRIDING the environment for keyed
 *   providers (`role('secret')`: persisted, redacted from every response);
 * - `<id>ApiKeyEnv` — the credential reference a keyed provider resolves;
 * - `<id>KeyPreset` — base-layer marker: the composition carries a literal
 *   key for this provider (the key itself never crosses the wire);
 * - `<id>BaseUrl` — the endpoint field of a base-URL provider (SearXNG).
 *
 * @param {ReturnType<providerCatalog>} catalog - the provider catalog.
 * @returns {z} the section schema.
 */
export const settingsConfig = (catalog) => z.object({
  provider: z.union([z.const(""), ...catalog.ids.map((id) => z.const(id))]).default(""),
  order: z.string().default(""),
  timeoutMs: z.number().step(1).min(100).default(10000),
  emptyResultsFallback: z.boolean().default(true),
  ...Object.fromEntries(catalog.keyed.flatMap((id) => [
    [`${id}ApiKey`, z.string().role("secret")],
    [`${id}ApiKeyEnv`, z.string().role("credential-ref").default(catalog.envOf(id))],
    [`${id}KeyPreset`, z.const(true)],
  ])),
  ...Object.fromEntries(catalog.ids.filter((id) => catalog.needsBaseUrl(id)).map((id) => [`${id}BaseUrl`, z.string().default("")])),
  // One declared field per provider carries its existence and display label
  // to the browser half — including pure keyless providers that have no
  // other field — so the card's catalog is complete without hardcoding ids.
  ...Object.fromEntries(catalog.ids.map((id) => {
    const marker = z.const(true);
    marker.meta = { ...marker.meta, providerLabel: catalog.labelOf(id) };
    return [`${id}Provider`, marker];
  })),
});

/**
 * Parse an `order` string into backend ids. Throws naming the bad token so
 * the settings service can refuse the write that produced it.
 *
 * @param {string} text - comma/space-separated backend ids.
 * @returns {string[]} the parsed, deduped id list.
 */
export function parseOrderString(text, knownIds) {
  const ids = String(text ?? "").split(/[\s,]+/u).filter((token) => token.length > 0);
  for (const id of ids) {
    if (!knownIds.includes(id)) {
      throw new Error(`search-router: unknown provider "${id}" in order (expected ${knownIds.join(", ")})`);
    }
  }
  return [...new Set(ids)];
}

/**
 * Cross-field validation for the settings register: exactly one of
 * provider/order, and the order list must parse. Runs on every write, so a
 * bad value is refused at save time rather than disabling the router.
 *
 * @param {object} section - the resolved settings section.
 */
export const validateSection = (catalog) => (section) => {
  if (section.provider !== "" && section.order.trim() !== "") {
    throw new Error('search-router: set either "provider" (single) or "order" (fallback chain), not both');
  }
  if (section.order.trim() !== "") {
    // ", ," parses to zero providers; an order that names nothing would
    // silently empty the chain, so refuse it at the same layer the
    // composition's parseConfig refuses an empty array.
    if (parseOrderString(section.order, catalog.ids).length === 0) {
      throw new Error(`search-router: "order" names no providers (expected ${catalog.ids.join(", ")})`);
    }
  }
  for (const id of catalog.ids.filter((candidate) => catalog.needsBaseUrl(candidate))) {
    const url = String(section[`${id}BaseUrl`] ?? "").trim();
    if (url === "") continue;
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      throw new Error(`search-router: ${id}BaseUrl must be a valid http(s) URL`);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new Error(`search-router: ${id}BaseUrl must be an http(s) URL`);
    }
  }
  for (const id of catalog.keyed) {
    const field = `${id}ApiKey`;
    if (section[field] !== undefined && String(section[field]).trim() === "") {
      throw new Error(`search-router: ${field} must be non-empty when set (unset it to fall back to the environment)`);
    }
  }
};

/**
 * Project the composition config into the flat settings shape, used as the
 * settings register's `base` layer: schema defaults < this base < user layer.
 * Every field is filled, so a resolved field equal to its base value means
 * "the user layer did not choose" and the composition value stays in force.
 *
 * @param {object} composition - the normalized plugin row config.
 * @returns {object} the flat base layer.
 */
export const projectBase = (catalog) => (composition) => {
  const section = (id) => composition.providers[id] ?? {};
  return {
    provider: composition.provider ?? "",
    order: (composition.order ?? []).join(", "),
    timeoutMs: composition.timeoutMs,
    emptyResultsFallback: composition.emptyResultsFallback,
    ...Object.fromEntries(catalog.keyed.map((id) => [`${id}ApiKeyEnv`, section(id).apiKeyEnv ?? catalog.envOf(id)])),
    // Flag — never the value — that the composition carries a literal key:
    // the card shows the provider as configured, the key stays off the wire.
    ...Object.fromEntries(catalog.keyed.filter((id) => typeof section(id).apiKey === "string").map((id) => [`${id}KeyPreset`, true])),
    ...Object.fromEntries(catalog.ids.filter((id) => catalog.needsBaseUrl(id)).map((id) => [`${id}BaseUrl`, section(id).baseURL ?? ""])),
  };
};

/**
 * Fold one resolved settings section over the composition config, producing
 * the effective router config (the shape {@link parseConfig} emits). A field
 * the user layer set differs from the base layer this section was resolved
 * against — that difference, not the resolved value alone, is what marks an
 * override, because schema defaults and the composition base both fill the
 * resolved section regardless of user choice.
 *
 * @param {object} composition - the normalized plugin row config.
 * @param {object | undefined} resolved - the resolved settings section, or
 *   undefined when the settings service is not available (pure composition).
 * @param {object} base - the base layer the section was resolved against
 *   (see {@link projectBase}); pass the same value used at registration.
 * @returns {object} the effective router config.
 */
export const mergeRuntime = (catalog) => (composition, resolved, base) => {
  if (resolved === undefined) return composition;
  const chosen = (field) => resolved[field] !== base[field];
  const merged = {
    timeoutMs: chosen("timeoutMs") ? resolved.timeoutMs : composition.timeoutMs,
    emptyResultsFallback: chosen("emptyResultsFallback") ? resolved.emptyResultsFallback : composition.emptyResultsFallback,
    providers: structuredClone(composition.providers),
  };
  // Routing precedence: a user-chosen fallback chain beats everything; next
  // a user-chosen single provider ("" = deliberately automatic, which also
  // clears a composition chain); with neither chosen, the composition's
  // routing stands. The section's own validate refuses provider+order set
  // together in one layer, but a composition/section mix reaches here and
  // must resolve the same way the GUI presents it: settings win.
  const orderChosen = chosen("order") && resolved.order.trim() !== "";
  const providerChosen = chosen("provider");
  if (orderChosen) {
    merged.order = parseOrderString(resolved.order, catalog.ids);
  } else if (providerChosen) {
    if (resolved.provider !== "") merged.provider = resolved.provider;
  } else if (composition.provider !== undefined) {
    merged.provider = composition.provider;
  } else if (composition.order !== undefined) {
    merged.order = composition.order;
  }
  const section = (id) => {
    merged.providers[id] ??= {};
    return merged.providers[id];
  };
  // Stored keys are the strongest key source: they land as the section's
  // literal `apiKey`, which `arm()` resolves before the credential
  // reference — overriding both the managed store and the environment.
  for (const id of catalog.keyed) {
    const field = `${id}ApiKey`;
    if (chosen(field)) section(id).apiKey = resolved[field] === undefined ? undefined : resolved[field];
    const envField = `${id}ApiKeyEnv`;
    if (chosen(envField)) section(id).apiKeyEnv = resolved[envField];
  }
  for (const id of catalog.ids.filter((candidate) => catalog.needsBaseUrl(candidate))) {
    const field = `${id}BaseUrl`;
    if (chosen(field)) section(id).baseURL = resolved[field] === "" ? undefined : resolved[field];
  }
  return merged;
};

/** DSH 0.2 search router: live Loader Config forms and native web_search. */
import z from '@deepseek-ai/schemastery';
import { parseConfig, createRouterProvider, BACKENDS } from './router.js';
import { settingsConfig, validateSection, parseOrderString, providerCatalog } from './settings.js';
export const name = 'search-router';
export const inject = ['web'];
const catalog = providerCatalog(BACKENDS);
const fields = settingsConfig(catalog).dict;
// Preserve advanced endpoint/model options from existing profile patches.
fields.providers = z.dict(z.object({
  apiKey: z.string().role('secret'), apiKeyEnv: z.string(),
  baseURL: z.string(), baseUrl: z.string(), baseUrlEnv: z.string(), model: z.string(),
})).hidden();
export const Config = z.object(Object.fromEntries(
  Object.entries(fields).map(([key, field]) => [key, field.volatile()]),
));
export function resolveConfig(config) {
  const flat = Object.fromEntries(Object.entries(config).map(([key, field]) => [key, field.get()]));
  validateSection(catalog)(flat);
  const providers = structuredClone(flat.providers ?? {});
  const section = id => (providers[id] ??= {});
  for (const id of catalog.keyed) {
    if (flat[`${id}ApiKey`] !== undefined) section(id).apiKey = flat[`${id}ApiKey`];
    section(id).apiKeyEnv = flat[`${id}ApiKeyEnv`];
  }
  for (const id of catalog.ids.filter(id => catalog.needsBaseUrl(id))) {
    if (flat[`${id}BaseUrl`]?.trim()) section(id).baseURL = flat[`${id}BaseUrl`].trim();
  }
  return parseConfig({
    ...(flat.provider ? {provider:flat.provider} : {}),
    ...(flat.order.trim() ? {order:parseOrderString(flat.order,catalog.ids)} : {}),
    timeoutMs:flat.timeoutMs, emptyResultsFallback:flat.emptyResultsFallback, providers,
  });
}
export function apply(ctx, config) {
  resolveConfig(config);
  // The custom browser panel owns this namespace's presentation.
  ctx.inject?.(['settings'], sctx => {
    if (typeof sctx.settings.configure === 'function')
      sctx.effect(() => sctx.settings.configure({auto:false}), 'search-router: custom settings panel');
  });
  ctx.web.registerSearchProvider(createRouterProvider(ctx, () => resolveConfig(config)));
}

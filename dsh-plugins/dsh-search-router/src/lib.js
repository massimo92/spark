/**
 * Shared plumbing for the provider adapters: HTTP transport with a
 * per-provider timeout, caller-cancellation propagation, and the mapping of
 * arbitrary provider result items onto the DSH `WebSearchSource` shape.
 *
 * Everything here uses the platform `fetch` and `AbortController` only; the
 * plugin's single runtime dependency (`@deepseek-ai/schemastery`) belongs to
 * the settings module, not this transport layer.
 */

import { readFileSync } from "node:fs";

/** Default per-provider timeout (ms). Overridable via the plugin config. */
export const DEFAULT_TIMEOUT_MS = 10000;

/** Attribution header sent to search providers; version from package.json. */
export const USER_AGENT = `dsh-search-router/${
  JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version
}`;

/** Hard cap on one source's snippet; long provider content is trimmed, never invented. */
const MAX_SNIPPET_CHARS = 400;

/** Cap for provider error details embedded in failure messages. */
const MAX_DETAIL_CHARS = 200;

/**
 * One linked abort signal: the provider timeout plus the caller's own
 * cancellation. Whichever fires first wins, and the reason distinguishes
 * caller cancellation (propagated as-is, stops the fallback chain) from a
 * provider timeout (counted as that provider's failure).
 *
 * @param {AbortSignal | undefined} signal - the caller's cancellation signal.
 * @param {number} timeoutMs - this provider's timeout budget.
 * @returns {{ inner: AbortSignal, cleanup: () => void }} the linked signal and its disposer.
 */
export function linkedSignal(signal, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error(`timeout after ${timeoutMs}ms`)), timeoutMs);
  const forward = () => controller.abort(signal.reason);
  if (signal !== undefined) {
    if (signal.aborted) controller.abort(signal.reason);
    else signal.addEventListener("abort", forward, { once: true });
  }
  const cleanup = () => {
    clearTimeout(timer);
    if (signal !== undefined) signal.removeEventListener("abort", forward);
  };
  return { inner: controller.signal, cleanup };
}

/** Short, safe rendering of an arbitrary thrown value (no headers, no keys). */
function brief(error) {
  const text = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  return text.length > MAX_DETAIL_CHARS ? `${text.slice(0, MAX_DETAIL_CHARS)}…` : text;
}

/** The error thrown when the CALLER (not the provider timeout) cancelled. */
export function callerAborted(signal) {
  const error = new Error("search aborted by caller", { cause: signal?.reason });
  error.callerAborted = true;
  return error;
}

/** True when an error is (or wraps) caller cancellation. */
export function isCallerAborted(error) {
  for (let current = error; current !== undefined; current = current?.cause) {
    if (current.callerAborted === true) return true;
    if (!(current instanceof Error)) return false;
  }
  return false;
}

/**
 * Fetch one URL and parse its JSON body. Failures are classified into the
 * plugin's short failure vocabulary — `timeout after Nms`, `network error`,
 * `HTTP <status>`, `unparseable JSON response` — so the router can log and
 * aggregate them without leaking request headers or credentials.
 *
 * @param {string} url - the request URL.
 * @param {RequestInit} init - fetch options (method/headers/body); the abort signal is attached here.
 * @param {{ signal?: AbortSignal, timeoutMs: number }} options - cancellation and timeout budget.
 * @returns {Promise<any>} the parsed JSON body.
 */
export async function httpJSON(url, init, options) {
  const text = await httpText(url, init, options);
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`unparseable JSON response: ${brief(error)}`);
  }
}

/**
 * Fetch one URL and return its body as text, with the same failure
 * classification as {@link httpJSON} — used by HTML-scraping backends
 * (DuckDuckGo), which must fail like any other provider.
 *
 * @param {string} url - the request URL.
 * @param {RequestInit} init - fetch options; the abort signal is attached here.
 * @param {{ signal?: AbortSignal, timeoutMs: number }} options - cancellation and timeout budget.
 * @returns {Promise<string>} the response body.
 */
export async function httpText(url, init, { signal, timeoutMs }) {
  const link = linkedSignal(signal, timeoutMs);
  let response;
  try {
    response = await fetch(url, { ...init, signal: link.inner });
  } catch (error) {
    if (signal?.aborted === true) throw callerAborted(signal);
    if (link.inner.aborted) throw new Error(`timeout after ${timeoutMs}ms`, { cause: error });
    throw new Error(`network error: ${brief(error)}`);
  } finally {
    link.cleanup();
  }
  if (!response.ok) throw new Error(`HTTP ${response.status}${await errorDetail(response)}`);
  return response.text();
}

/**
 * Extract a short provider-supplied detail from an error response body.
 * Best-effort on purpose: a status code alone is already actionable.
 *
 * @param {Response} response - the failed response.
 * @returns {Promise<string>} `""` or `: <detail>`.
 */
async function errorDetail(response) {
  let detail = "";
  try {
    const parsed = await response.json();
    const raw = typeof parsed?.error === "string"
      ? parsed.error
      : typeof parsed?.error?.message === "string"
        ? parsed.error.message
        : typeof parsed?.detail === "string"
          ? parsed.detail
          : typeof parsed?.message === "string" ? parsed.message : "";
    if (raw.length > 0) detail = `: ${raw}`;
  } catch {
    /* a status code alone is fine */
  }
  return detail.length > MAX_DETAIL_CHARS ? `${detail.slice(0, MAX_DETAIL_CHARS)}…` : detail;
}

/** A non-empty string, or undefined. */
function nonEmpty(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/**
 * Map one provider result item onto the DSH source shape. Only portable
 * fields survive (`url`, `title`, `snippet`, `publishedAt`); provider-score
 * or raw-content fields are dropped at this boundary. Items without a usable
 * URL and dates that no `Date` can parse are rejected rather than guessed.
 *
 * @param {unknown} item - one raw provider result item.
 * @returns {{ url: string, title?: string, snippet?: string, publishedAt?: string } | undefined}
 */
export function toSource(item) {
  if (item === null || typeof item !== "object") return undefined;
  const url = nonEmpty(item.url);
  if (url === undefined) return undefined;
  const source = { url };
  const title = nonEmpty(item.title);
  if (title !== undefined) source.title = title;
  const snippet = nonEmpty(item.snippet) ?? nonEmpty(item.text) ?? nonEmpty(item.content) ?? nonEmpty(item.description);
  if (snippet !== undefined) source.snippet = truncate(stripTags(snippet), MAX_SNIPPET_CHARS);
  const publishedAt = dateField(item.publishedAt ?? item.publishedDate ?? item.published_date ?? item.page_age ?? item.date ?? item.age);
  if (publishedAt !== undefined) source.publishedAt = publishedAt;
  return source;
}

/** Keep a candidate date field only when `Date` can parse it and it stays short. */
function dateField(value) {
  const text = nonEmpty(value);
  if (text === undefined || text.length > 40 || Number.isNaN(Date.parse(text))) return undefined;
  return text;
}

/** Trim to a cap with an ellipsis marker; never lengthens. */
function truncate(text, cap) {
  return text.length > cap ? `${text.slice(0, cap)}…` : text;
}

/**
 * Drop HTML markup from a provider snippet (Brave bold-marks the query with
 * `<b>` tags; other providers occasionally ship anchors). Snippets are plain
 * text on the model surface, so markup is noise, not information.
 *
 * @param {string} text - the raw provider snippet.
 * @returns {string} the snippet without any tags.
 */
function stripTags(text) {
  return text.replace(/<\/?[a-z][^>]*>/giu, "");
}

/**
 * Normalize a provider's raw result list: keep only mappable items, dedupe
 * by URL (first occurrence wins), and cap at `maxResults` when set. The
 * returned `truncated` flags that the cap dropped mappable items, so the
 * caller can report it honestly (the seam only flags ITS own cut).
 *
 * @param {unknown[]} items - raw provider result items.
 * @param {number | undefined} maxResults - the request's result bound.
 * @returns {{ sources: object[], truncated: boolean }} normalized sources.
 */
export function normalizeSources(items, maxResults) {
  const seen = new Set();
  const sources = [];
  let truncated = false;
  for (const item of Array.isArray(items) ? items : []) {
    const source = toSource(item);
    if (source === undefined || seen.has(source.url)) continue;
    if (maxResults !== undefined && sources.length >= maxResults) {
      truncated = true;
      break;
    }
    seen.add(source.url);
    sources.push(source);
  }
  return { sources, truncated };
}

/**
 * Resolve `path` against a base URL while preserving the base's own path —
 * `new URL("/x", "https://h/sub")` would drop `/sub`, and self-hosted
 * SearXNG instances are commonly proxied under a subpath.
 *
 * @param {string} base - the provider's base URL (trailing slash optional).
 * @param {string} path - the endpoint path relative to the base.
 * @returns {URL} the request URL.
 */
export function joinURL(base, path) {
  return new URL(path, base.endsWith("/") ? base : `${base}/`);
}

/** Clamp a requested result count into a provider's supported range. */
export function clampCount(maxResults, fallback, max) {
  const count = typeof maxResults === "number" && Number.isInteger(maxResults) && maxResults > 0 ? maxResults : fallback;
  return Math.min(count, max);
}

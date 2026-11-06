import { join } from "node:path";
import { homedir } from "node:os";
import { readdir, rm, stat } from "node:fs/promises";

/**
 * Session Delete bundle — Host half.
 *
 * Exposes `POST /api/session-delete` (JSON `{ sessionId }`) for the Client
 * half's menu row. One request performs the whole delete:
 *
 * 1. Archive the Session with `stopActivity` — its running turns, jobs,
 *    subagents and schedules are stopped and any later wake is gated, so no
 *    work can append to the log being removed. (An already-archived Session
 *    resolves here without a stop pass; archiving never gated nothing.)
 * 2. Detach the Session from every Workspace account, so the sidebar list
 *    drops the row through the regular workspace follow stream.
 * 3. Remove the persisted Session logs under `$DSH_HOME/sessions` and drop
 *    the projection-cache entry (best effort).
 *
 * The archived id remains in the registry's global archive set as a
 * tombstone: it keeps any residual live Agent gated and the row hidden on
 * every grouping surface, and a phantom id is pruned from Workspace accounts
 * by the registry's own candidate check on the next write.
 */

/** A Session id is a flat token; anything path-shaped is rejected outright. */
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$/;
/** The JSON body cap for this endpoint; a delete request is tiny. */
const MAX_BODY_BYTES = 64 * 1024;

function dshHome() {
	return process.env.DSH_HOME || join(homedir(), ".dsh");
}

function readJsonBody(req) {
	return new Promise((resolve, reject) => {
		let size = 0;
		const chunks = [];
		req.on("data", (chunk) => {
			size += chunk.length;
			if (size > MAX_BODY_BYTES) {
				reject(new Error("request body too large"));
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on("end", () => {
			try {
				resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
			} catch {
				reject(new Error("request body is not valid JSON"));
			}
		});
		req.on("error", reject);
	});
}

function sendJson(res, status, value) {
	if (res.headersSent) {
		res.destroy();
		return;
	}
	const body = JSON.stringify(value);
	res.writeHead(status, {
		"content-type": "application/json; charset=utf-8",
		"content-length": Buffer.byteLength(body),
		"cache-control": "no-store",
	});
	res.end(body);
}

/** Whether `error` is the registry's "no such session anywhere" outcome. */
function isUnknownSession(error) {
	return error instanceof Error && (error.name === "WorkspaceUnknownSessionError" || error.constructor?.name === "WorkspaceUnknownSessionError");
}

/** Remove every persisted log directory named exactly `sessionId`. */
async function deleteSessionLogs(sessionId) {
	const root = join(dshHome(), "sessions");
	const removed = [];
	let projects;
	try {
		projects = await readdir(root, { withFileTypes: true });
	} catch {
		return removed;
	}
	for (const project of projects) {
		if (!project.isDirectory()) continue;
		const candidate = join(root, project.name, sessionId);
		if (!candidate.startsWith(root + "/")) continue;
		try {
			if ((await stat(candidate)).isDirectory()) {
				await rm(candidate, { recursive: true, force: true });
				removed.push(candidate);
			}
		} catch {
			/* An absent project entry is the normal case; anything else is logged by the caller's tally. */
		}
	}
	return removed;
}

async function deleteProjectionCache(sessionId) {
	if (!SESSION_ID.test(sessionId)) return;
	try {
		await rm(join(dshHome(), "storages", "session_projcache", "sessions", `${sessionId}.json`), { force: true });
	} catch {
		/* The projection cache is derived state; a stale entry is invisible garbage. */
	}
}

export const inject = ["webServer", "workspaceRegistry", "connection"];

export function apply(ctx) {
	return ctx.effect(() => {
		const disposeRoute = ctx.webServer.register({
			kind: "exact",
			path: "/api/session-delete",
			handler: async (req, res) => {
				try {
					if (req.method !== "POST") {
						res.writeHead(405, { allow: "POST" }).end();
						return;
					}
					if (!ctx.connection.authorizeIndex(req, res)) return;
					// A strict JSON content type keeps simple cross-site form posts from triggering a delete.
					if (!String(req.headers["content-type"] ?? "").includes("application/json")) {
						sendJson(res, 415, { error: "expected an application/json request body" });
						return;
					}
					const body = await readJsonBody(req);
					const sessionId = body?.sessionId;
					if (typeof sessionId !== "string" || !SESSION_ID.test(sessionId)) {
						sendJson(res, 400, { error: "sessionId is missing or malformed" });
						return;
					}
					try {
						await ctx.workspaceRegistry.archiveSession(sessionId, { stopActivity: true });
					} catch (error) {
						if (!isUnknownSession(error)) throw error;
					}
					for (const workspace of ctx.workspaceRegistry.list()) {
						try {
							await workspace.detachSession(sessionId);
						} catch (error) {
							ctx.logger.warn(`session-delete: detaching '${sessionId}' from workspace '${workspace.id}' failed: ${String(error)}`);
						}
					}
					const removed = await deleteSessionLogs(sessionId);
					await deleteProjectionCache(sessionId);
					sendJson(res, 200, { ok: true, logsRemoved: removed.length });
				} catch (error) {
					ctx.logger.warn(`session-delete: request failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
					sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
				}
			},
		});
		return () => disposeRoute();
	}, "session-delete: route");
}

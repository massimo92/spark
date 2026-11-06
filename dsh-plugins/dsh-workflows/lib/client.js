/**
 * dsh-workflows — mitad CLIENTE (navegador).
 *
 * JavaScript plano, sin build: el module loader de DSH ejecuta este script y
 * React llega del propio DSH (`require("react")`). Aporta:
 *   - una pestaña "Workflows" en la barra lateral derecha del chat
 *     (biblioteca, editor de fases, lanzar desde una fase, ejecución);
 *   - una franja sobre el input mientras un workflow corre en la conversación;
 *   - un botón junto al input para abrir la pestaña.
 * Habla con la mitad host solo por las rutas autenticadas /api/workflows.*.
 */
window.__ModuleLoader__.load({
	id: "@local/dsh-workflows",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		const React = require("react");
		const { createElement: h, Fragment, useEffect, useMemo, useRef, useState, useSyncExternalStore } = React;
		const UI = require("@deepseek-ai/dsh-client-ui-primitives");

		//#region constantes

		const ROUTE_PREFIX = "api/workflows.";
		const TAB_ID = "@local/dsh-workflows/panel";
		const TAB_KIND = "dshWorkflows";
		const NAME_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
		const POLL_MS = 1000;

		const STATE_LABEL = {
			pending: "En cola",
			running: "En curso",
			"waiting-input": "Te toca",
			"waiting-confirm": "Espera tu OK",
			error: "Error"
		};
		const STATE_TONE = {
			pending: "neutral",
			running: "info",
			"waiting-input": "warning",
			"waiting-confirm": "info",
			error: "danger"
		};

		//#endregion
		//#region estilos

		const CSS = `
.dshwf{display:flex;flex-direction:column;gap:10px;padding:12px 14px 0;font-size:13px;line-height:1.45;color:var(--dsw-alias-label-primary);height:100%;min-height:0;overflow-y:auto;box-sizing:border-box}
.dshwf *{box-sizing:border-box}
.dshwf-head{display:flex;align-items:center;gap:8px;min-height:28px}
.dshwf-title{font-weight:500;font-size:14px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dshwf-muted{color:var(--dsw-alias-label-tertiary);font-size:12px}
.dshwf-sec{color:var(--dsw-alias-label-secondary);font-size:12px}
.dshwf-err{color:var(--dsw-alias-state-error-primary);font-size:12px}
.dshwf-icon{width:26px;height:26px;display:inline-flex;align-items:center;justify-content:center;border:none;background:none;border-radius:999px;color:var(--dsw-alias-label-tertiary);cursor:pointer;padding:0;flex:none}
.dshwf-icon:hover{background:var(--dsw-alias-interactive-bg-hover);color:var(--dsw-alias-label-secondary)}
.dshwf-icon.accent{color:var(--dsw-alias-state-business-primary)}
.dshwf-icon.danger:hover{background:var(--dsw-alias-interactive-bg-hover-danger,var(--dsw-alias-interactive-bg-hover));color:var(--dsw-alias-state-error-primary)}
.dshwf-icon:disabled{opacity:.35;cursor:default}
.dshwf-row{display:flex;align-items:flex-start;gap:8px;padding:9px 10px;border:.5px solid var(--dsw-alias-border-l2);border-radius:var(--dsw-radius-md,8px);background:var(--dsw-alias-bg-base);cursor:pointer;text-align:left;width:100%;color:inherit;font:inherit}
.dshwf-row:hover{background:var(--dsw-alias-interactive-bg-hover)}
.dshwf-row.active{border-color:var(--dsw-alias-state-business-primary)}
.dshwf-field{display:flex;flex-direction:column;gap:3px}
.dshwf-label{font-size:12px;color:var(--dsw-alias-label-secondary)}
.dshwf-input,.dshwf-textarea,.dshwf-select{width:100%;border:.5px solid var(--dsw-alias-border-l4);border-radius:var(--dsw-radius-sm,6px);background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;outline:none;padding:5px 8px}
.dshwf-input,.dshwf-select{height:30px}
.dshwf-textarea{resize:vertical;min-height:58px;line-height:1.45}
.dshwf-input:focus,.dshwf-textarea:focus,.dshwf-select:focus{border-color:var(--dsw-alias-state-business-primary)}
.dshwf-input::placeholder,.dshwf-textarea::placeholder{color:var(--dsw-alias-label-caption)}
.dshwf-flow{display:flex;flex-direction:column}
.dshwf-step{display:flex;gap:8px}
.dshwf-rail{display:flex;flex-direction:column;align-items:center;width:20px;flex:none;padding-top:7px}
.dshwf-line{flex:1;width:1px;background:var(--dsw-alias-border-l3);min-height:8px;margin-top:4px}
.dshwf-card{flex:1;min-width:0;border:.5px solid var(--dsw-alias-border-l2);border-radius:var(--dsw-radius-md,8px);background:var(--dsw-alias-bg-base);padding:7px 9px;margin-bottom:8px}
.dshwf-card.open{border-color:var(--dsw-alias-border-l4)}
.dshwf-card.cur{border-color:var(--dsw-alias-state-business-primary)}
.dshwf-card.wait{border-color:var(--dsw-alias-state-warn-label,#b7791f)}
.dshwf-card.bad{border-color:var(--dsw-alias-state-error-primary)}
.dshwf-card.dim{opacity:.6}
.dshwf-cardhead{display:flex;align-items:center;gap:6px;cursor:pointer;min-height:24px}
.dshwf-num{width:18px;height:18px;border-radius:50%;border:.5px solid var(--dsw-alias-border-l4);font-size:10px;display:inline-flex;align-items:center;justify-content:center;color:var(--dsw-alias-label-secondary);flex:none}
.dshwf-chips{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px}
.dshwf-chip{display:inline-flex;align-items:center;gap:3px;padding:0 6px;border-radius:var(--dsw-radius-sm,6px);font-size:11px;line-height:18px;border:.5px solid var(--dsw-alias-border-l3);color:var(--dsw-alias-label-secondary);white-space:nowrap;max-width:100%;overflow:hidden;text-overflow:ellipsis}
.dshwf-chip.accent{color:var(--dsw-alias-state-business-primary);border-color:var(--dsw-alias-state-business-primary)}
.dshwf-chip.warn{color:var(--dsw-alias-state-warn-label,#b7791f);border-color:var(--dsw-alias-state-warn-label,#b7791f)}
.dshwf-chip button{border:none;background:none;color:inherit;cursor:pointer;padding:0;display:inline-flex}
.dshwf-body{display:flex;flex-direction:column;gap:8px;margin-top:8px}
.dshwf-grid2{display:grid;grid-template-columns:minmax(0,1.5fr) minmax(0,1fr);gap:8px}
.dshwf-foot{display:flex;align-items:center;gap:6px;margin-top:auto;padding:8px 0 12px;position:sticky;bottom:0;z-index:1;background:var(--dsw-alias-bg-base);border-top:.5px solid var(--dsw-alias-border-l2)}
.dshwf-spacer{flex:1}
.dshwf-banner{display:flex;align-items:center;gap:8px;padding:7px 9px;border-radius:var(--dsw-radius-md,8px);border:.5px solid var(--dsw-alias-border-l3);background:var(--dsw-alias-bg-layer-1,transparent);font-size:12px}
.dshwf-banner.bad{border-color:var(--dsw-alias-state-error-primary);color:var(--dsw-alias-state-error-primary)}
.dshwf-banner.ok{border-color:var(--dsw-alias-border-l4)}
.dshwf-dots{display:flex;align-items:center;gap:3px;color:var(--dsw-alias-label-tertiary)}
.dshwf-dash{width:8px;height:1px;background:var(--dsw-alias-border-l4)}
.dshwf-add{display:flex;align-items:center;gap:6px;color:var(--dsw-alias-label-tertiary);font-size:12px;border:none;background:none;cursor:pointer;padding:2px 0 2px 28px;font:inherit}
.dshwf-add:hover{color:var(--dsw-alias-label-secondary)}
.dshwf-warn{color:var(--dsw-alias-state-warn-label,#b7791f);font-size:12px}
.dshwf-boxwrap{position:relative}
.dshwf-boxwrap .dshwf-textarea{padding-right:28px}
.dshwf-expand{position:absolute;top:4px;right:4px;width:22px;height:22px;display:inline-flex;align-items:center;justify-content:center;border:none;border-radius:var(--dsw-radius-sm,6px);background:transparent;color:var(--dsw-alias-label-tertiary);cursor:pointer;padding:0}
.dshwf-expand:hover{background:var(--dsw-alias-interactive-bg-hover);color:var(--dsw-alias-label-secondary)}
.dshwf-modal{width:min(960px,92vw)!important;max-width:min(960px,92vw)!important}
.dshwf-modalcontent{width:100%!important;max-width:none!important}
.dshwf-bigarea{width:100%;min-height:min(60vh,560px);font-size:14px;line-height:1.55;resize:vertical;box-sizing:border-box}
.dshwf-modalfoot{display:flex;align-items:center;gap:8px;width:100%}
.dshwf-spin{animation:dshwf-spin 1s linear infinite}
@keyframes dshwf-spin{to{transform:rotate(360deg)}}
.dshwf-dock{box-sizing:border-box;container-type:inline-size;flex:none;min-width:0;width:calc(100% - var(--dsh-composer-side-clearance,16px)*2 - var(--dsh-composer-dock-inset,8px)*4);max-width:calc(var(--dsh-composer-card-max-width,760px) - var(--dsh-composer-dock-inset,8px)*4);margin:0 auto}
.dshwf-bubble{--dshwf-ease:cubic-bezier(.23,1,.32,1);position:relative;isolation:isolate;width:fit-content;max-width:100%;margin:0 auto;border-radius:22px;background:var(--dsw-specific-menu,var(--dsw-alias-bg-base));box-shadow:var(--dsw-elevation-panel);color:var(--dsw-alias-label-primary);font-size:13px;line-height:1.45}
.dshwf-bubble *{box-sizing:border-box}
.dshwf-bubble [hidden]{display:none!important}
.dshwf-bubble.expanded{width:100%;border-radius:var(--dsw-radius-lg,14px)}
.dshwf-bubble button{font:inherit;cursor:pointer}
.dshwf-bubble button:focus-visible{outline:2px solid var(--dsw-alias-state-business-primary);outline-offset:2px}
.dshwf-bubble-toggle{position:absolute;inset:0;z-index:1;width:100%;height:100%;background:none;border:0;border-radius:inherit;padding:0}
.dshwf-bubble-content{position:relative;z-index:2;pointer-events:none;padding:7px 12px}
.dshwf-bubble-content button{pointer-events:auto}
.dshwf-bubble-summary{display:flex;align-items:center;flex-wrap:wrap;gap:8px;min-height:26px}
.dshwf-bubble-title{font-weight:500;min-width:0;overflow-wrap:anywhere;max-width:260px}
.dshwf-bubble.expanded .dshwf-bubble-title{flex:1;max-width:none}
.dshwf-bubble-count{font-size:12px;font-variant-numeric:tabular-nums;color:var(--dsw-alias-label-tertiary)}
.dshwf-docs-summary,.dshwf-files-toggle{border:0;background:none;border-radius:6px;color:var(--dsw-alias-label-secondary);padding:4px;font-size:12px!important;text-align:left;line-height:1.5;white-space:normal}
.dshwf-docs-summary{margin-left:auto}
.dshwf-files-toggle{margin:4px 0 0 -4px}
.dshwf-files-toggle[aria-expanded=true]{color:var(--dsw-alias-label-tertiary);font-weight:400}
.dshwf-mini-route{display:flex;gap:3px;flex:none;width:48px}
.dshwf-progress-phase{display:block;min-width:0;flex:1}
.dshwf-progress-rail{display:block;position:relative;overflow:hidden;height:3px;border-radius:3px;background:var(--dsw-alias-border-l3)}
.dshwf-progress-rail.mini{height:4px}
.dshwf-progress-phase.done .dshwf-progress-rail{background:var(--dsw-alias-label-tertiary)}
.dshwf-progress-phase.current .dshwf-progress-rail{background:var(--dsw-alias-state-business-primary)}
.dshwf-bubble.running .dshwf-progress-phase.current .dshwf-progress-rail:after{content:"";position:absolute;inset:0;transform:translateX(-100%);background:linear-gradient(90deg,transparent,var(--dsw-alias-bg-base),transparent);opacity:.6;animation:dshwf-progress 1.7s linear infinite}
@keyframes dshwf-progress{to{transform:translateX(100%)}}
.dshwf-route-grid{display:grid;grid-template-columns:repeat(var(--dshwf-columns,4),minmax(0,1fr));gap:12px;margin-top:11px;padding:0 3px 5px;max-height:min(40vh,320px);overflow-y:auto;overscroll-behavior:contain;pointer-events:auto}
.dshwf-route-phase{min-width:0;font-size:12px}
.dshwf-route-title{display:flex;gap:4px;align-items:flex-start;margin-top:8px;overflow-wrap:anywhere;color:var(--dsw-alias-label-secondary)}
.dshwf-route-title svg{margin-top:3px}
.dshwf-route-phase.current .dshwf-route-title{font-weight:500;color:var(--dsw-alias-label-primary)}
.dshwf-route-phase.skipped .dshwf-route-title{text-decoration:line-through}
.dshwf-route-status{display:block;margin-top:5px;font-size:11px;color:var(--dsw-alias-label-tertiary)}
.dshwf-phase-files{list-style:none;display:flex;flex-direction:column;gap:2px;margin:3px 0 0;padding:0}
.dshwf-artifact{display:flex;align-items:flex-start;gap:5px;max-width:100%;width:100%;padding:4px 0;text-align:left;border:0;background:none;border-radius:5px;color:var(--dsw-alias-label-primary);font-size:12px!important}
.dshwf-artifact svg{margin-top:2px}
.dshwf-artifact span{min-width:0;overflow-wrap:anywhere}
.dshwf-bubble-prompt{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-top:6px;font-size:12px;max-width:600px}
.dshwf-bubble-prompt>span{flex:1;min-width:150px;overflow-wrap:anywhere}
.dshwf-bubble-actions{display:flex;gap:5px;align-items:center;margin-top:8px;padding-top:5px;border-top:.5px solid var(--dsw-alias-border-l2)}
.dshwf-bubble-actions>button:not(.dshwf-icon){border:0;background:none;color:var(--dsw-alias-label-tertiary);font-size:12px;padding:4px 0;border-radius:5px}
.dshwf-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}
@container (max-width:480px){.dshwf-route-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.dshwf-bubble-summary{gap:6px}.dshwf-bubble-title{max-width:180px}.dshwf-mini-route{width:36px}}
@media(hover:hover) and (pointer:fine){.dshwf-bubble-toggle:hover,.dshwf-docs-summary:hover,.dshwf-files-toggle:hover,.dshwf-artifact:hover{background:var(--dsw-alias-interactive-bg-hover)}}
@media(pointer:coarse){.dshwf-bubble button:not(.dshwf-bubble-toggle){min-height:44px}.dshwf-bubble .dshwf-icon{min-width:44px}}
@media(prefers-reduced-motion:reduce){.dshwf-bubble.running .dshwf-progress-phase.current .dshwf-progress-rail:after{animation:none;transform:none;opacity:.25}}
`;
		function installCss() {
			if (typeof document === "undefined") return () => {};
			const id = "@local/dsh-workflows";
			if (document.querySelector(`style[data-plugin-css=${JSON.stringify(id)}]`) !== null) return () => {};
			const tag = document.createElement("style");
			tag.dataset.pluginCss = id;
			tag.textContent = CSS;
			document.head.appendChild(tag);
			return () => tag.remove();
		}

		//#endregion
		//#region iconos (trazos estilo Tabler, currentColor)

		const PATHS = {
			file: ["M14 2H6a2 2 0 0 0 -2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2V8z", "M14 2v6h6", "M8 13h8", "M8 17h6"],
			route: ["M3 19a2 2 0 1 0 4 0a2 2 0 0 0 -4 0", "M19 7a2 2 0 1 0 0 -4a2 2 0 0 0 0 4z", "M11 19h5.5a3.5 3.5 0 0 0 0 -7h-8a3.5 3.5 0 0 1 0 -7h4.5"],
			play: ["M7 4v16l13 -8z"],
			stop: ["M6 6h12v12h-12z"],
			skip: ["M4 5v14l12 -7z", "M20 5l0 14"],
			check: ["M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0 -18 0", "M9 12l2 2l4 -4"],
			circle: ["M12 12m-8 0a8 8 0 1 0 16 0a8 8 0 1 0 -16 0"],
			user: ["M8 7a4 4 0 1 0 8 0a4 4 0 0 0 -8 0", "M6 21v-2a4 4 0 0 1 4 -4h4a4 4 0 0 1 4 4v2"],
			alert: ["M12 9v4", "M12 17h.01", "M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0z"],
			plus: ["M12 5l0 14", "M5 12l14 0"],
			trash: ["M4 7l16 0", "M10 11l0 6", "M14 11l0 6", "M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12", "M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"],
			copy: ["M8 8m0 2a2 2 0 0 1 2 -2h8a2 2 0 0 1 2 2v8a2 2 0 0 1 -2 2h-8a2 2 0 0 1 -2 -2z", "M16 8v-2a2 2 0 0 0 -2 -2h-8a2 2 0 0 0 -2 2v8a2 2 0 0 0 2 2h2"],
			up: ["M12 5l0 14", "M18 11l-6 -6", "M6 11l6 -6"],
			down: ["M12 5l0 14", "M18 13l-6 6", "M6 13l6 6"],
			back: ["M5 12l14 0", "M5 12l6 6", "M5 12l6 -6"],
			chevDown: ["M6 9l6 6l6 -6"],
			chevUp: ["M6 15l6 -6l6 6"],
			loader: ["M12 3a9 9 0 1 0 9 9"],
			hand: ["M8 13v-7.5a1.5 1.5 0 0 1 3 0v6.5", "M11 5.5v-2a1.5 1.5 0 1 1 3 0v8.5", "M14 5.5a1.5 1.5 0 0 1 3 0v6.5", "M17 7.5a1.5 1.5 0 0 1 3 0v8.5a6 6 0 0 1 -6 6h-2a6 6 0 0 1 -5 -2.7l-3.3 -5.7a1.5 1.5 0 0 1 .5 -2a1.9 1.9 0 0 1 2.3 .3l1.5 1.5"],
			send: ["M10 14l11 -11", "M21 3l-6.5 18a.55 .55 0 0 1 -1 0l-3.5 -7l-7 -3.5a.55 .55 0 0 1 0 -1l18 -6.5"],
			x: ["M18 6l-12 12", "M6 6l12 12"],
			expand: ["M16 4l4 0l0 4", "M14 10l6 -6", "M8 20l-4 0l0 -4", "M4 20l6 -6"],
			search: ["M10 10m-7 0a7 7 0 1 0 14 0a7 7 0 1 0 -14 0", "M21 21l-6 -6"],
			dashed: ["M8.56 3.69a9 9 0 0 0 -2.92 1.95", "M3.69 8.56a9 9 0 0 0 -.69 3.44", "M3.69 15.44a9 9 0 0 0 1.95 2.92", "M8.56 20.31a9 9 0 0 0 3.44 .69", "M15.44 20.31a9 9 0 0 0 2.92 -1.95", "M20.31 15.44a9 9 0 0 0 .69 -3.44", "M20.31 8.56a9 9 0 0 0 -1.95 -2.92", "M15.44 3.69a9 9 0 0 0 -3.44 -.69"]
		};
		function Icon({ name, size = 14, className, style }) {
			return h("svg", {
				width: size,
				height: size,
				viewBox: "0 0 24 24",
				fill: "none",
				stroke: "currentColor",
				strokeWidth: 1.8,
				strokeLinecap: "round",
				strokeLinejoin: "round",
				"aria-hidden": "true",
				className,
				style: { flex: "none", ...style }
			}, (PATHS[name] ?? []).map((d, i) => h("path", { key: i, d })));
		}
		const WorkflowGlyph = (props) => h(Icon, { name: "route", size: props?.size ?? 16 });
		function IconButton({ icon, label, onClick, tone, disabled, size = 14 }) {
			return h("button", {
				type: "button",
				className: `dshwf-icon${tone ? ` ${tone}` : ""}`,
				title: label,
				"aria-label": label,
				disabled,
				onClick: (event) => {
					event.stopPropagation();
					onClick?.(event);
				}
			}, h(Icon, { name: icon, size }));
		}
		function Btn({ children, onClick, variant = "outline", icon, disabled, title }) {
			return h(UI.Button, { type: "button", size: "sm", variant, icon: icon ? h(Icon, { name: icon, size: 13 }) : undefined, disabled, title, onClick }, children);
		}

		//#endregion
		//#region datos

		/** Rutas relativas, igual que los plugins del núcleo (`api/changes.summary`). */
		function createApi() {
			return async function call(endpoint, payload) {
				const response = await fetch(`${ROUTE_PREFIX}${endpoint}`, {
					method: "POST",
					headers: { "content-type": "application/json" },
					body: JSON.stringify(payload ?? {})
				});
				if (!response.ok) throw new Error(`HTTP ${response.status} en ${endpoint}`);
				const result = await response.json();
				if (!result.ok) throw new Error(result.error?.message ?? "Error desconocido");
				return result.value;
			};
		}

		/** Estado observable mínimo para useSyncExternalStore. */
		function createSource(initial) {
			let snapshot = initial;
			const listeners = new Set();
			return {
				get: () => snapshot,
				set: (next) => {
					snapshot = typeof next === "function" ? next(snapshot) : next;
					for (const listener of listeners) listener();
				},
				subscribe: (listener) => {
					listeners.add(listener);
					return () => listeners.delete(listener);
				},
				size: () => listeners.size
			};
		}

		function createStores(call) {
			const library = createSource({ status: "idle", workflows: [], error: null });
			const catalog = createSource({ status: "idle", models: { default: null, groups: [] }, skills: [], error: null });
			const runs = new Map();
			const refreshLibrary = async () => {
				library.set((s) => ({ ...s, status: s.workflows.length ? "ready" : "loading" }));
				try {
					const value = await call("list");
					library.set({ status: "ready", workflows: value.workflows, error: null });
				} catch (error) {
					library.set((s) => ({ ...s, status: "error", error: error.message }));
				}
			};
			const refreshCatalog = async (sessionId) => {
				try {
					const value = await call("catalog", { sessionId });
					catalog.set({ status: "ready", ...value, error: null });
				} catch (error) {
					catalog.set((s) => ({ ...s, status: "error", error: error.message }));
				}
			};
			function runSource(sessionId) {
				let entry = runs.get(sessionId);
				if (entry !== undefined) return entry;
				const source = createSource({ run: null, notice: null, loaded: false });
				let timer;
				let inflight = false;
				let revision = 0;
				const refresh = async () => {
					if (inflight) return;
					inflight = true;
					const before = revision;
					try {
						const value = await call("state", { sessionId });
						if (before === revision) source.set({ ...value, loaded: true });
					} catch {
						// el siguiente sondeo lo vuelve a intentar
					} finally {
						inflight = false;
					}
				};
				const subscribe = (listener) => {
					const off = source.subscribe(listener);
					if (timer === undefined) {
						void refresh();
						timer = setInterval(() => void refresh(), POLL_MS);
					}
					return () => {
						off();
						if (source.size() === 0 && timer !== undefined) {
							clearInterval(timer);
							timer = undefined;
						}
					};
				};
				entry = { get: source.get, set: (value) => { revision += 1; source.set(value); }, invalidate: () => { revision += 1; }, subscribe, refresh };
				runs.set(sessionId, entry);
				return entry;
			}
			/** Acción sobre la ejecución: aplica el estado que devuelve el host. */
			const act = async (sessionId, endpoint, payload) => {
				runSource(sessionId).invalidate();
				const value = await call(endpoint, { sessionId, ...payload });
				runSource(sessionId).set({ ...value, loaded: true });
				return value;
			};
			return { call, library, catalog, refreshLibrary, refreshCatalog, runSource, act };
		}

		const useSource = (source) => useSyncExternalStore(source.subscribe, source.get, source.get);

		function useNow(active) {
			const [now, setNow] = useState(() => Date.now());
			useEffect(() => {
				if (!active) return undefined;
				const id = setInterval(() => setNow(Date.now()), 1000);
				return () => clearInterval(id);
			}, [active]);
			return now;
		}

		function duration(ms) {
			const s = Math.max(0, Math.round(ms / 1000));
			const m = Math.floor(s / 60);
			return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : m > 0 ? `${m}:${String(s % 60).padStart(2, "0")}` : `0:${String(s).padStart(2, "0")}`;
		}

		const newPhase = (n) => ({ id: crypto.randomUUID(), name: `Fase ${n}`, input: "auto", instructions: "", question: "", skills: [], model: null, effort: null, afterward: "continue", output: "" });
		const newWorkflow = () => ({ name: "", description: "", phases: [newPhase(1)] });

		function modelKey(model) {
			return model ? `${model.provider}::${model.model}` : "";
		}
		function findModel(catalog, model) {
			if (!model) return undefined;
			const group = catalog.models.groups.find((g) => g.id === model.provider);
			return group?.models.find((m) => m.id === model.model);
		}
		function modelLabel(catalog, model) {
			if (!model) return "sesión";
			return findModel(catalog, model)?.name ?? model.model;
		}
		function effortLabel(catalog, phase) {
			if (!phase.effort) return null;
			const model = findModel(catalog, phase.model ?? catalog.models.default ?? undefined);
			return model?.reasoning?.efforts?.find((e) => e.id === phase.effort)?.name ?? phase.effort;
		}

		/** Validación local rápida antes de guardar (el host valida de verdad). */
		function draftProblem(draft) {
			if (!draft.name.trim()) return "Ponle un nombre para guardarlo";
			if (!NAME_PATTERN.test(draft.name.trim())) return "Nombre: solo minúsculas, números y guiones (como las skills)";
			if (draft.phases.length === 0) return "Añade al menos una fase";
			const empty = draft.phases.findIndex((p) => p.input === "auto" && !p.instructions.trim());
			if (empty !== -1) return `Fase ${empty + 1}: una fase automática necesita instrucciones`;
			const unnamed = draft.phases.findIndex((p) => !p.name.trim());
			if (unnamed !== -1) return `Fase ${unnamed + 1}: falta el nombre`;
			return null;
		}

		//#endregion
		//#region piezas comunes

		function Header({ title, onBack, right, onClose }) {
			return h("div", { className: "dshwf-head" },
				onBack ? h(IconButton, { icon: "back", label: "Volver", onClick: onBack }) : h("span", { style: { color: "var(--dsw-alias-label-tertiary)", display: "inline-flex" } }, h(WorkflowGlyph, null)),
				h("span", { className: "dshwf-title" }, title),
				right ?? null,
				onClose ? h(IconButton, { icon: "x", label: "Cerrar", onClick: onClose }) : null);
		}

		function StateTag({ state }) {
			return h(UI.Tag, { tone: STATE_TONE[state] ?? "neutral" }, STATE_LABEL[state] ?? state);
		}

		function PhaseChips({ phase, catalog }) {
			const effort = effortLabel(catalog, phase);
			return h("div", { className: "dshwf-chips" },
				h("span", { className: `dshwf-chip${phase.model || phase.effort ? " accent" : ""}`, title: "Modelo · esfuerzo" }, `${modelLabel(catalog, phase.model)}${effort ? ` · ${effort}` : ""}`),
				h("span", { className: `dshwf-chip${phase.input === "user" ? " warn" : ""}` }, h(Icon, { name: phase.input === "user" ? "user" : "send", size: 11 }), phase.input === "user" ? "tu mensaje" : "auto"),
				phase.skills.map((s) => h("span", { key: s, className: "dshwf-chip", title: "Skill" }, `/${s}`)),
				null,
				phase.afterward === "confirm" ? h("span", { className: "dshwf-chip" }, h(Icon, { name: "hand", size: 11 }), "espera tu OK") : null);
		}

		function StatusIcon({ status, index }) {
			switch (status) {
				case "done": return h(Icon, { name: "check", size: 16, style: { color: "var(--dsw-alias-state-success-primary, #2f9e44)" } });
				case "running":
				case "pending": return h(Icon, { name: "loader", size: 16, className: "dshwf-spin", style: { color: "var(--dsw-alias-state-business-primary)" } });
				case "waiting-input": return h(Icon, { name: "user", size: 16, style: { color: "var(--dsw-alias-state-warn-label, #b7791f)" } });
				case "waiting-confirm": return h(Icon, { name: "hand", size: 16, style: { color: "var(--dsw-alias-state-business-primary)" } });
				case "error": return h(Icon, { name: "alert", size: 16, style: { color: "var(--dsw-alias-state-error-primary)" } });
				case "skipped": return h(Icon, { name: "dashed", size: 16, style: { color: "var(--dsw-alias-label-tertiary)" } });
				case "todo": return h(Icon, { name: "circle", size: 16, style: { color: "var(--dsw-alias-label-tertiary)" } });
				default: return h("span", { className: "dshwf-num" }, String(index + 1));
			}
		}

		function NoticeBanner({ notice, onLaunchFrom, onDismiss }) {
			if (!notice) return null;
			const stopped = notice.kind === "stopped";
			return h("div", { className: `dshwf-banner ${stopped ? "bad" : "ok"}` },
				h(Icon, { name: stopped ? "stop" : "check", size: 14 }),
				h("span", { className: "dshwf-spacer" }, stopped
					? `${notice.name}: detenido en la fase ${notice.index + 1}/${notice.total}`
					: `${notice.name}: completado · ${notice.total} fases · ${duration(notice.durationMs)}`),
				stopped && onLaunchFrom ? h(Btn, { icon: "play", onClick: () => onLaunchFrom(notice.workflowId, notice.index) }, `Desde fase ${notice.index + 1}`) : null,
				h(IconButton, { icon: "x", label: "Descartar", onClick: onDismiss }));
		}

		//#endregion
		//#region biblioteca

		function Library({ stores, state, sessionId, onOpen, onNew, onLaunch, onShowRun }) {
			const lib = useSource(stores.library);
			const [query, setQuery] = useState("");
			useEffect(() => {
				void stores.refreshLibrary();
			}, []);
			const q = query.trim().toLowerCase();
			const list = lib.workflows.filter((w) => !q || w.name.includes(q) || w.description.toLowerCase().includes(q));
			return h(Fragment, null,
				h(Header, { title: "Workflows" }),
				h(NoticeBanner, {
					notice: state.run ? null : state.notice,
					onLaunchFrom: (id, index) => onLaunch(id, index),
					onDismiss: () => void stores.act(sessionId, "dismiss").catch(() => {})
				}),
				state.run ? h("button", { type: "button", className: "dshwf-row active", onClick: onShowRun },
					h(Icon, { name: "play", size: 14, style: { color: "var(--dsw-alias-state-business-primary)", marginTop: 2 } }),
					h("div", { className: "dshwf-spacer", style: { minWidth: 0 } },
						h("div", { style: { fontWeight: 500 } }, state.run.name),
						h("div", { className: "dshwf-muted" }, `Fase ${state.run.index + 1}/${state.run.phases.length} · ${state.run.phases[state.run.index]?.name ?? ""}`)),
					h(StateTag, { state: state.run.state })) : null,
				lib.workflows.length > 4 ? h(UI.Input, { placeholder: "Buscar", value: query, onChange: (e) => setQuery(e.target.value), icon: h(Icon, { name: "search", size: 13 }) }) : null,
				lib.status === "error" ? h("div", { className: "dshwf-err" }, lib.error) : null,
				lib.status !== "error" && lib.workflows.length === 0 && lib.status === "ready" ? h("div", { className: "dshwf-banner" },
					h("div", null,
						h("div", { style: { fontWeight: 500 } }, "Crea tu primer workflow"),
						h("div", { className: "dshwf-sec" }, "Como una skill con varias fases: en cada una decides qué instrucciones ocultas recibe el modelo, cuándo arranca, qué skills carga y con qué modelo y esfuerzo."))) : null,
				list.map((w) => h("div", { key: w.id, className: "dshwf-row", role: "button", tabIndex: 0, onClick: () => onOpen(w.id), onKeyDown: (e) => { if (e.key === "Enter") onOpen(w.id); } },
					h("div", { className: "dshwf-spacer", style: { minWidth: 0 } },
						h("div", { style: { display: "flex", gap: 6, alignItems: "baseline" } },
							h("span", { style: { fontWeight: 500 } }, w.name)),
						w.description ? h("div", { className: "dshwf-sec", style: { margin: "2px 0 4px" } }, w.description) : null,
						h("div", { className: "dshwf-dots" },
							w.phases.map((p, i) => h(Fragment, { key: p.id },
								i > 0 ? h("span", { className: "dshwf-dash" }) : null,
								h(Icon, { name: p.input === "user" ? "user" : "circle", size: p.input === "user" ? 12 : 8, style: p.input === "user" ? { color: "var(--dsw-alias-state-warn-label, #b7791f)" } : undefined }))),
							h("span", { className: "dshwf-muted", style: { marginLeft: 6 } }, `${w.phases.length} ${w.phases.length === 1 ? "fase" : "fases"}`))),
					h(IconButton, { icon: "play", label: "Ejecutar en esta conversación", tone: "accent", disabled: Boolean(state.run), onClick: () => onLaunch(w.id, 0) }))),
				h("div", { className: "dshwf-foot" },
					h(Btn, { icon: "plus", onClick: onNew }, "Nuevo workflow")));
		}

		//#endregion
		//#region editor

		/**
		 * Caja de texto con botón ⤢ que abre un editor grande flotante.
		 * El editor grande trabaja sobre una copia: Aceptar (⌘Enter) la aplica,
		 * Cancelar (Esc) la descarta.
		 */
		function TextBox({ label, hint, value, onChange, placeholder, rows = 3, disabled, title }) {
			const [big, setBig] = useState(null);
			const accept = () => {
				onChange(big);
				setBig(null);
			};
			return h("div", { className: "dshwf-field" },
				label ? h("span", { className: "dshwf-label" }, label) : null,
				h("div", { className: "dshwf-boxwrap" },
					h("textarea", { className: "dshwf-textarea", rows, value, placeholder, disabled, onChange: (e) => onChange(e.target.value) }),
					disabled ? null : h("button", {
						type: "button",
						className: "dshwf-expand",
						title: "Editar en grande",
						"aria-label": "Editar en grande",
						onClick: () => setBig(value)
					}, h(Icon, { name: "expand", size: 13 }))),
				hint ? h("span", { className: "dshwf-muted" }, hint) : null,
				h(UI.Modal, {
					open: big !== null,
					onClose: () => setBig(null),
					title: title ?? label ?? "Editar",
					closeLabel: "Cerrar",
					className: "dshwf-modal",
					contentClassName: "dshwf-modalcontent",
					footer: h("div", { className: "dshwf-modalfoot" },
						h("span", { className: "dshwf-muted" }, `${(big ?? "").length.toLocaleString()} caracteres · ⌘Enter acepta · Esc cancela`),
						h("span", { className: "dshwf-spacer" }),
						h(Btn, { onClick: () => setBig(null) }, "Cancelar"),
						h(Btn, { variant: "primary", onClick: accept }, "Aceptar"))
				}, h("textarea", {
					className: "dshwf-textarea dshwf-bigarea",
					autoFocus: true,
					value: big ?? "",
					placeholder,
					onChange: (e) => setBig(e.target.value),
					onKeyDown: (e) => {
						if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
							e.preventDefault();
							accept();
						}
					}
				})));
		}

		function PhaseEditor({ phase, index, total, catalog, onChange, onMove, onRemove, onRunFrom, canRun }) {
			const set = (patch) => onChange({ ...phase, ...patch });
			const [skillPick, setSkillPick] = useState("");
			const model = findModel(catalog, phase.model ?? catalog.models.default ?? undefined);
			const efforts = model?.reasoning?.efforts ?? [];
			const available = catalog.skills.filter((s) => !phase.skills.includes(s.name));
			return h("div", { className: "dshwf-body" },
				h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Nombre"),
					h("input", { className: "dshwf-input", value: phase.name, onChange: (e) => set({ name: e.target.value }) })),
				h(TextBox, {
					label: "Instrucciones",
					title: `Instrucciones · fase ${index + 1} · ${phase.name}`,
					hint: "El modelo las recibe al empezar la fase. No aparecen en el chat.",
					rows: 4,
					value: phase.instructions,
					placeholder: phase.input === "user" ? "Opcional. Qué hacer con tu mensaje, p. ej.: aplica solo los cambios que te indique." : "Qué tiene que hacer el modelo en esta fase",
					onChange: (value) => set({ instructions: value })
				}),
				h(TextBox, {
					label: "Salida",
					title: `Salida · fase ${index + 1} · ${phase.name}`,
					hint: "Opcional. Formato del archivo de resultado de la fase (~/.dsh/scratch/workflows). El modelo recibe su ruta y los archivos de las fases anteriores.",
					rows: 3,
					value: phase.output ?? "",
					placeholder: "Secciones y orden del archivo que debe dejar esta fase",
					onChange: (value) => set({ output: value })
				}),
				h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Inicio"),
					h(UI.SegmentedControl, {
						id: `dshwf-input-${index}`,
						label: "Inicio de la fase",
						value: phase.input,
						options: [{ value: "auto", label: "Automático" }, { value: "user", label: "Espera tu mensaje" }],
						onChange: (value) => set({ input: value })
					}),
					h("span", { className: "dshwf-muted" }, phase.input === "user"
						? "La fase arranca con lo que escribas en el chat; tu mensaje se envía tal cual."
						: "La fase arranca sola; en el chat solo aparece una marca con su nombre.")),
				phase.input === "user" ? h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Pregunta que te muestra la barra"),
					h("input", { className: "dshwf-input", value: phase.question, placeholder: "¿Qué cambios aplico?", onChange: (e) => set({ question: e.target.value }) })) : null,
				h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Skills que se cargan en esta fase"),
					phase.skills.length ? h("div", { className: "dshwf-chips", style: { marginTop: 0 } }, phase.skills.map((s) => h("span", { key: s, className: "dshwf-chip accent" }, `/${s}`,
						h("button", { type: "button", "aria-label": `Quitar ${s}`, onClick: () => set({ skills: phase.skills.filter((x) => x !== s) }) }, h(Icon, { name: "x", size: 11 }))))) : null,
					h("select", {
						className: "dshwf-select",
						value: skillPick,
						onChange: (e) => {
							const name = e.target.value;
							setSkillPick("");
							if (name) set({ skills: [...phase.skills, name] });
						}
					}, h("option", { value: "" }, catalog.status === "ready" ? (available.length ? "Añadir skill…" : "No hay más skills") : "Cargando skills…"),
						available.map((s) => h("option", { key: s.name, value: s.name, title: s.description }, s.name)))),
				h("div", { className: "dshwf-grid2" },
					h("div", { className: "dshwf-field" },
						h("span", { className: "dshwf-label" }, "Modelo"),
						h("select", {
							className: "dshwf-select",
							value: modelKey(phase.model),
							onChange: (e) => {
								const value = e.target.value;
								if (!value) return set({ model: null, effort: null });
								const cut = value.indexOf("::");
								set({ model: { provider: value.slice(0, cut), model: value.slice(cut + 2) }, effort: null });
							}
						}, h("option", { value: "" }, "Heredar de la sesión"),
							catalog.models.groups.map((g) => h("optgroup", { key: g.id, label: g.name }, g.models.map((m) => h("option", { key: m.id, value: `${g.id}::${m.id}` }, m.name)))),
							phase.model && !findModel(catalog, phase.model) ? h("option", { value: modelKey(phase.model) }, `${phase.model.model} (no disponible)`) : null)),
					h("div", { className: "dshwf-field" },
						h("span", { className: "dshwf-label" }, "Esfuerzo"),
						h("select", {
							className: "dshwf-select",
							value: phase.effort ?? "",
							disabled: efforts.length === 0 && !phase.effort,
							onChange: (e) => set({ effort: e.target.value || null })
						}, h("option", { value: "" }, efforts.length ? "Heredar" : "—"),
							efforts.map((ef) => h("option", { key: ef.id, value: ef.id }, ef.name)),
							phase.effort && !efforts.some((ef) => ef.id === phase.effort) ? h("option", { value: phase.effort }, phase.effort) : null))),
				h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Al terminar la fase"),
					h(UI.SegmentedControl, {
						id: `dshwf-after-${index}`,
						label: "Al terminar",
						value: phase.afterward,
						options: [{ value: "continue", label: "Pasar a la siguiente" }, { value: "confirm", label: "Esperar tu OK" }],
						onChange: (value) => set({ afterward: value })
					})),
				h("div", { style: { display: "flex", alignItems: "center", gap: 2 } },
					h(IconButton, { icon: "up", label: "Subir", disabled: index === 0, onClick: () => onMove(-1) }),
					h(IconButton, { icon: "down", label: "Bajar", disabled: index === total - 1, onClick: () => onMove(1) }),
					h("span", { className: "dshwf-spacer" }),
					canRun ? h(Btn, { icon: "play", variant: "ghost", onClick: onRunFrom }, "Ejecutar desde aquí") : null,
					h(IconButton, { icon: "trash", label: "Borrar fase", tone: "danger", disabled: total === 1, onClick: onRemove })));
		}

		function Editor({ stores, workflowId, sessionId, running, onBack, onLaunch, onOpen }) {
			const lib = useSource(stores.library);
			const catalog = useSource(stores.catalog);
			const stored = workflowId ? lib.workflows.find((w) => w.id === workflowId) : undefined;
			const [draft, setDraft] = useState(() => stored ? structuredClone(stored) : newWorkflow());
			const [open, setOpen] = useState(stored ? -1 : 0);
			const [saving, setSaving] = useState(false);
			const [error, setError] = useState(null);
			const [leaving, setLeaving] = useState(false);
			const [confirmDelete, setConfirmDelete] = useState(false);
			const [savedJson, setSavedJson] = useState(() => stored ? JSON.stringify(stored) : null);
			const problem = draftProblem(draft);
			const dirty = JSON.stringify(draft) !== savedJson;
			const saved = Boolean(draft.id) && !dirty;
			useEffect(() => {
				void stores.refreshCatalog(sessionId);
			}, [sessionId]);

			/** Guarda y devuelve el workflow guardado (o null si no se pudo). */
			const save = async () => {
				if (problem) {
					setError(problem);
					return null;
				}
				setSaving(true);
				setError(null);
				try {
					const { workflow } = await stores.call("save", { workflow: draft });
					setDraft(workflow);
					setSavedJson(JSON.stringify(workflow));
					void stores.refreshLibrary();
					return workflow;
				} catch (e) {
					setError(e.message);
					return null;
				} finally {
					setSaving(false);
				}
			};
			const saveRef = useRef(save);
			saveRef.current = save;
			const onKeyDown = (e) => {
				if (e.key === "s" && (e.metaKey || e.ctrlKey)) {
					e.preventDefault();
					void saveRef.current();
				}
			};
			const back = () => {
				if (dirty) setLeaving(true);
				else onBack();
			};
			const launch = async (index) => {
				const workflow = dirty || !draft.id ? await save() : draft;
				if (workflow) onLaunch(workflow.id, index);
			};

			const updatePhase = (i, next) => setDraft((d) => ({ ...d, phases: d.phases.map((p, j) => (j === i ? next : p)) }));
			const movePhase = (i, delta) => setDraft((d) => {
				const phases = d.phases.slice();
				const j = i + delta;
				if (j < 0 || j >= phases.length) return d;
				[phases[i], phases[j]] = [phases[j], phases[i]];
				setOpen(j);
				return { ...d, phases };
			});
			const removePhase = (i) => {
				setDraft((d) => ({ ...d, phases: d.phases.filter((_, j) => j !== i) }));
				setOpen(-1);
			};
			const addPhase = () => {
				setDraft((d) => ({ ...d, phases: [...d.phases, newPhase(d.phases.length + 1)] }));
				setOpen(draft.phases.length);
			};
			const remove = async () => {
				if (!draft.id) return onBack();
				if (!confirmDelete) {
					setConfirmDelete(true);
					setTimeout(() => setConfirmDelete(false), 3000);
					return;
				}
				try {
					await stores.call("delete", { id: draft.id });
					await stores.refreshLibrary();
					onBack();
				} catch (e) {
					setError(e.message);
				}
			};
			const duplicate = async () => {
				if (!saved) return;
				const names = new Set(lib.workflows.map((w) => w.name));
				let name = `${draft.name}-copia`;
				for (let n = 2; names.has(name); n++) name = `${draft.name}-copia-${n}`;
				try {
					const { workflow } = await stores.call("save", { workflow: { ...draft, id: undefined, name, phases: draft.phases.map((p) => ({ ...p, id: crypto.randomUUID() })) } });
					await stores.refreshLibrary();
					onOpen(workflow.id);
				} catch (e) {
					setError(e.message);
				}
			};
			const status = saving ? "Guardando…" : dirty ? "Cambios sin guardar" : "Guardado";

			return h("div", { style: { display: "contents" }, onKeyDown },
				h(Header, { title: draft.name || "Nuevo workflow", onBack: back, right: h("span", { className: dirty ? "dshwf-warn" : "dshwf-muted" }, status) }),
				leaving ? h("div", { className: "dshwf-banner" },
					h("span", { className: "dshwf-spacer" }, "Tienes cambios sin guardar"),
					h(Btn, { variant: "ghost", onClick: () => setLeaving(false) }, "Seguir editando"),
					h(Btn, { onClick: () => onBack() }, "Descartar"),
					h(Btn, { variant: "primary", onClick: async () => {
						if (await save()) onBack();
						else setLeaving(false);
					} }, "Guardar")) : null,
				h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Nombre"),
					h("input", { className: "dshwf-input", value: draft.name, placeholder: "review-pr", autoFocus: !stored, onChange: (e) => setDraft((d) => ({ ...d, name: e.target.value.toLowerCase().replace(/\s+/g, "-") })) })),
				h(TextBox, {
					label: "Descripción",
					rows: 2,
					value: draft.description,
					placeholder: "Para qué sirve y cuándo usarlo",
					onChange: (value) => setDraft((d) => ({ ...d, description: value }))
				}),
				h("div", { className: "dshwf-flow" }, draft.phases.map((phase, i) => {
					const isOpen = open === i;
					return h("div", { key: phase.id ?? `new-${i}`, className: "dshwf-step" },
						h("div", { className: "dshwf-rail" }, h(StatusIcon, { status: "idle", index: i }), i < draft.phases.length - 1 ? h("div", { className: "dshwf-line" }) : null),
						h("div", { className: `dshwf-card${isOpen ? " open" : ""}` },
							h("div", { className: "dshwf-cardhead", onClick: () => setOpen(isOpen ? -1 : i) },
								h("span", { style: { fontWeight: 500, flex: 1, minWidth: 0 } }, phase.name || `Fase ${i + 1}`),
								!isOpen && !running ? h(IconButton, { icon: "play", label: dirty ? "Guardar y ejecutar desde aquí" : "Ejecutar desde aquí", tone: "accent", onClick: () => void launch(i) }) : null,
								h(Icon, { name: isOpen ? "chevUp" : "chevDown", size: 14, style: { color: "var(--dsw-alias-label-tertiary)" } })),
							isOpen ? null : h(PhaseChips, { phase, catalog }),
							isOpen ? h(PhaseEditor, {
								phase,
								index: i,
								total: draft.phases.length,
								catalog,
								canRun: !running,
								onChange: (next) => updatePhase(i, next),
								onMove: (delta) => movePhase(i, delta),
								onRemove: () => removePhase(i),
								onRunFrom: () => void launch(i)
							}) : null));
				})),
				h("button", { type: "button", className: "dshwf-add", onClick: addPhase }, h(Icon, { name: "plus", size: 13 }), "Añadir fase"),
				error ? h("div", { className: "dshwf-err" }, error) : null,
				h("div", { className: "dshwf-foot" },
					h(IconButton, { icon: "trash", label: confirmDelete ? "Pulsa otra vez para borrar" : "Borrar workflow", tone: "danger", onClick: remove }),
					confirmDelete ? h("span", { className: "dshwf-err" }, "Pulsa otra vez para borrar") : null,
					h(IconButton, { icon: "copy", label: "Duplicar", disabled: !saved, onClick: duplicate }),
					h("span", { className: "dshwf-spacer" }),
					h(Btn, { variant: dirty ? "primary" : "outline", disabled: saving || !dirty, title: "Guardar (⌘S)", onClick: () => void save() }, "Guardar"),
					h(Btn, { icon: "play", disabled: running || saving, title: running ? "Ya hay un workflow en marcha en esta conversación" : dirty ? "Guarda y ejecuta" : undefined, onClick: () => void launch(0) }, "Ejecutar")));
		}

		//#endregion
		//#region lanzar

		function Launch({ stores, sessionId, workflowId, startIndex, onBack, onStarted }) {
			const lib = useSource(stores.library);
			const workflow = lib.workflows.find((w) => w.id === workflowId);
			const [start, setStart] = useState(startIndex ?? 0);
			const [context, setContext] = useState("");
			const [busy, setBusy] = useState(false);
			const [error, setError] = useState(null);
			if (!workflow) return h(Fragment, null, h(Header, { title: "Ejecutar", onBack }), h("div", { className: "dshwf-err" }, "Ese workflow ya no existe."));
			const run = async () => {
				setBusy(true);
				setError(null);
				try {
					await stores.act(sessionId, "run", { workflowId, startIndex: start, context });
					onStarted();
				} catch (e) {
					setError(e.message);
					setBusy(false);
				}
			};
			return h(Fragment, null,
				h(Header, { title: `Ejecutar ${workflow.name}`, onBack }),
				h("div", { className: "dshwf-sec" }, "En esta conversación"),
				h("div", { className: "dshwf-field" },
					h("span", { className: "dshwf-label" }, "Empezar en"),
					h("select", { className: "dshwf-select", value: start, onChange: (e) => setStart(Number(e.target.value)) },
						workflow.phases.map((p, i) => h("option", { key: p.id, value: i }, `Fase ${i + 1} · ${p.name}`)))),
				h("div", { className: "dshwf-flow" }, workflow.phases.map((p, i) => h("div", { key: p.id, className: "dshwf-step" },
					h("div", { className: "dshwf-rail" }, h(StatusIcon, { status: i < start ? "skipped" : i === start ? "idle" : "todo", index: i }), i < workflow.phases.length - 1 ? h("div", { className: "dshwf-line" }) : null),
					h("div", { className: `dshwf-card${i < start ? " dim" : i === start ? " cur" : ""}` },
						h("div", { style: { fontWeight: 500, textDecoration: i < start ? "line-through" : "none" } }, p.name),
						i < start ? h("div", { className: "dshwf-muted" }, "Se salta") : h(PhaseChips, { phase: p, catalog: stores.catalog.get() }))))),
				h(TextBox, {
					label: "Contexto inicial (opcional)",
					hint: "Se añade, oculto, a las instrucciones de la primera fase que ejecutes.",
					rows: 2,
					value: context,
					placeholder: "La rama es feature/oee-iso; céntrate en service.py",
					onChange: setContext
				}),
				error ? h("div", { className: "dshwf-err" }, error) : null,
				h("div", { className: "dshwf-foot" },
					h("span", { className: "dshwf-spacer" }),
					h(Btn, { onClick: onBack }, "Cancelar"),
					h(Btn, { icon: "play", variant: "primary", disabled: busy, onClick: run }, "Ejecutar")));
		}

		//#endregion
		//#region ejecución

		function phaseStatus(run, i) {
			if (i < run.startIndex || run.skipped?.includes(i)) return "skipped";
			if (run.completed?.includes(i) || run.kind === "completed") return "done";
			if (i < run.index) return "done";
			if (i === run.index) return run.state;
			return "todo";
		}

		function RunView({ stores, sessionId, state, onBack }) {
			const run = state.run;
			const catalog = useSource(stores.catalog);
			const now = useNow(Boolean(run));
			const [error, setError] = useState(null);
			const act = async (endpoint, payload) => {
				setError(null);
				try {
					await stores.act(sessionId, endpoint, payload);
				} catch (e) {
					setError(e.message);
				}
			};
			if (!run) {
				return h(Fragment, null,
					h(Header, { title: "Ejecución", onBack }),
					h(NoticeBanner, { notice: state.notice, onDismiss: () => void act("dismiss") }),
					h("div", { className: "dshwf-muted" }, "No hay ningún workflow en marcha en esta conversación."));
			}
			return h(Fragment, null,
				h(Header, { title: run.name, onBack, right: h(StateTag, { state: run.state }) }),
				h("div", { className: "dshwf-muted" }, `Fase ${run.index + 1}/${run.phases.length} · ${duration(now - run.startedAt)} en total`),
				h("div", { className: "dshwf-flow" }, run.phases.map((p, i) => {
					const status = phaseStatus(run, i);
					const current = i === run.index;
					const cls = current ? (run.state === "error" ? " bad" : run.state === "waiting-input" ? " wait" : " cur") : status === "skipped" || status === "todo" ? " dim" : "";
					return h("div", { key: i, className: "dshwf-step" },
						h("div", { className: "dshwf-rail" }, h(StatusIcon, { status, index: i }), i < run.phases.length - 1 ? h("div", { className: "dshwf-line" }) : null),
						h("div", { className: `dshwf-card${cls}` },
							h("div", { style: { fontWeight: current ? 500 : 400, textDecoration: status === "skipped" ? "line-through" : "none" } }, p.name),
							h(PhaseChips, { phase: p, catalog }),
							current ? h(CurrentPhase, { run, phase: p, now, act }) : null));
				})),
				run.warnings?.length ? h("div", { className: "dshwf-muted" }, run.warnings.join(" · ")) : null,
				error ? h("div", { className: "dshwf-err" }, error) : null,
				h("div", { className: "dshwf-foot" },
					h("span", { className: "dshwf-spacer" }),
					h(Btn, { icon: "stop", onClick: () => void act("stop") }, "Detener")));
		}

		function CurrentPhase({ run, phase, now, act }) {
			const [extra, setExtra] = useState("");
			const elapsed = duration(now - run.phaseStartedAt);
			switch (run.state) {
				case "pending":
					return h("div", { className: "dshwf-muted", style: { marginTop: 6 } }, "Empieza cuando termine el turno en curso.");
				case "running":
					return h("div", { style: { display: "flex", alignItems: "center", marginTop: 6, gap: 6 } },
						h("span", { className: "dshwf-muted", style: { flex: 1 } }, `${elapsed} · si escribes en el chat, corriges esta fase`),
						h(Btn, { icon: "skip", variant: "ghost", onClick: () => void act("skip") }, "Saltar"));
				case "waiting-input":
					return h("div", { style: { marginTop: 6, display: "flex", flexDirection: "column", gap: 6 } },
						h("div", { style: { color: "var(--dsw-alias-state-warn-label, #b7791f)" } }, phase.question || "Escribe en el chat para arrancar esta fase"),
						h("div", { style: { display: "flex", alignItems: "center", gap: 6 } },
							h("span", { className: "dshwf-muted", style: { flex: 1 } }, "Lo que envíes desde el chat es el input de esta fase."),
							h(Btn, { icon: "skip", variant: "ghost", onClick: () => void act("skip") }, "Saltar")));
				case "waiting-confirm": {
					const last = run.index + 1 >= run.phases.length;
					return h("div", { style: { marginTop: 6, display: "flex", flexDirection: "column", gap: 6 } },
						h(TextBox, { rows: 2, value: extra, title: last ? "Fase terminada" : `Instrucciones extra para «${run.phases[run.index + 1].name}»`, placeholder: last ? "Fase terminada" : `Instrucciones extra para «${run.phases[run.index + 1].name}» (opcionales, ocultas)`, disabled: last, onChange: setExtra }),
						h("div", { style: { display: "flex", gap: 6, justifyContent: "flex-end" } },
							h(Btn, { variant: "primary", onClick: () => void act("continue", { extra }) }, last ? "Terminar" : extra.trim() ? "Continuar con esto" : "Continuar")));
				}
				case "error":
					return h("div", { style: { marginTop: 6, display: "flex", flexDirection: "column", gap: 6 } },
						h("div", { className: "dshwf-err" }, run.error ?? "La fase falló"),
						h("div", { style: { display: "flex", gap: 6 } },
							h(Btn, { onClick: () => void act("retry") }, "Reintentar"),
							h(Btn, { variant: "ghost", onClick: () => void act("skip") }, "Saltar")));
				default:
					return null;
			}
		}

		//#endregion
		//#region pestaña

		function WorkflowsTab({ sessionId, stores }) {
			const runSource = useMemo(() => stores.runSource(sessionId), [stores, sessionId]);
			const state = useSource(runSource);
			const [view, setView] = useState({ kind: "library" });
			const lastRun = useRef(null);
			useEffect(() => {
				void stores.refreshLibrary();
				void stores.refreshCatalog(sessionId);
			}, [sessionId]);
			useEffect(() => {
				const id = state.run?.id ?? null;
				if (id !== null && id !== lastRun.current) setView({ kind: "run" });
				if (id === null && lastRun.current !== null && view.kind === "run") setView({ kind: "library" });
				lastRun.current = id;
			}, [state.run?.id]);
			const go = {
				library: () => setView({ kind: "library" }),
				open: (id) => setView({ kind: "edit", id }),
				new: () => setView({ kind: "edit", id: null }),
				launch: (id, index) => setView({ kind: "launch", id, index }),
				run: () => setView({ kind: "run" })
			};
			let content;
			if (view.kind === "edit") content = h(Editor, { key: view.id ?? "new", stores, sessionId, workflowId: view.id, running: Boolean(state.run), onBack: go.library, onLaunch: go.launch, onOpen: go.open });
			else if (view.kind === "launch") content = h(Launch, { stores, sessionId, workflowId: view.id, startIndex: view.index, onBack: go.library, onStarted: go.run });
			else if (view.kind === "run") content = h(RunView, { stores, sessionId, state, onBack: go.library });
			else content = h(Library, { stores, state, sessionId, onOpen: go.open, onNew: go.new, onLaunch: go.launch, onShowRun: go.run });
			return h("div", { className: "dshwf" }, content);
		}

		//#endregion
		//#region franja sobre el input

		function WorkflowDock({ sessionId, stores, openPanel, openFile }) {
			const runSource = useMemo(() => stores.runSource(sessionId), [stores, sessionId]);
			const state = useSource(runSource);
			const run = state.run ?? (state.notice?.phases ? state.notice : null);
			return run ? h(WorkflowBubble, { key: `${sessionId}:${run.id}`, run, sessionId, stores, openPanel, openFile, active: Boolean(state.run) }) : null;
		}

		function WorkflowBubble({ run, sessionId, stores, openPanel, openFile, active }) {
			const [expanded, setExpanded] = useState(false);
			const [groups, setGroups] = useState({});
			const [error, setError] = useState(null);
			const [busy, setBusy] = useState(false);
			const toggle = useRef(null);
			const acting = useRef(false);
			const phase = run.phases[run.index];
			const files = run.files ?? [];
			const count = new Set(files.map((file) => file.path)).size;
			const routeId = `dshwf-route-${encodeURIComponent(sessionId)}-${run.id}`;
			const running = active && run.state === "running";
			const title = !active ? (run.kind === "completed" ? "Completado" : "Detenido") : phase?.name ?? run.name;
			const statusLabel = (i) => {
				const status = phaseStatus(run, i);
				return ({ done: "Completada", skipped: "Omitida", todo: active ? "Pendiente" : "Sin ejecutar", pending: "En cola", running: "En curso", "waiting-input": "Te toca", "waiting-confirm": "Espera tu OK", error: "Error", stopped: "Detenida" })[status] ?? status;
			};
			const stateClass = (i) => {
				const status = phaseStatus(run, i);
				return status === "done" ? "done" : status === "skipped" ? "skipped" : i === run.index && active ? "current" : "future";
			};
			const act = async (endpoint) => {
				if (acting.current) return;
				acting.current = true;
				setBusy(true);
				setError(null);
				try { await stores.act(sessionId, endpoint); }
				catch (e) { setError(e.message); }
				finally { acting.current = false; setBusy(false); }
			};
			const read = async (file) => {
				setError(null);
				try { await openFile(sessionId, file.path); }
				catch (e) { setError(`No se pudo abrir ${file.name}: ${e.message}`); }
			};
			let prompt = null;
			let action = null;
			if (active && run.state === "waiting-input") prompt = phase.question || "Escribe en el chat para empezar esta fase.";
			if (active && run.state === "waiting-confirm") {
				prompt = "Fase completada. Espera tu OK.";
				action = h(Btn, { variant: "primary", disabled: busy, onClick: () => void act("continue") }, run.index + 1 < run.phases.length ? "Continuar" : "Terminar");
			}
			if (active && run.state === "error") {
				prompt = run.error || "La fase falló.";
				action = h(Btn, { disabled: busy, onClick: () => void act("retry") }, "Reintentar");
			}
			const rail = (i, mini = false) => h("span", { key: i, className: `dshwf-progress-phase ${stateClass(i)}`, "aria-hidden": true }, h("span", { className: `dshwf-progress-rail${mini ? " mini" : ""}` }));
			return h("div", { className: "dshwf-dock" },
				h("section", {
					className: `dshwf-bubble${expanded ? " expanded" : ""}${running ? " running" : ""}`,
					"aria-label": `Workflow ${run.name}`,
					"data-testid": "workflow-bubble",
					onKeyDown: (event) => {
						if (event.key === "Escape" && expanded) { event.stopPropagation(); toggle.current?.focus(); setExpanded(false); }
					}
				},
					h("button", {
						ref: toggle, type: "button", className: "dshwf-bubble-toggle",
						"aria-expanded": expanded, "aria-controls": routeId,
						"aria-label": `${expanded ? "Colapsar" : "Desplegar"} ${run.name}: ${title}, fase ${Math.min(run.index + 1, run.phases.length)} de ${run.phases.length}`,
						onClick: () => setExpanded((value) => !value)
					}),
					h("div", { className: "dshwf-bubble-content" },
						h("div", { className: "dshwf-bubble-summary" },
							expanded ? h(Icon, { name: active ? "route" : run.kind === "completed" ? "check" : "stop", size: 15 }) : h("span", { className: "dshwf-mini-route" }, run.phases.map((_, i) => rail(i, true))),
							h("span", { className: "dshwf-bubble-title", title: `${run.name} · ${title}` }, title),
							h("span", { className: "dshwf-bubble-count" }, `${Math.min(run.index + 1, run.phases.length)}/${run.phases.length}`),
							h("button", {
								type: "button", className: "dshwf-docs-summary", "aria-label": `Ver ${count} archivos por fase`,
								onClick: () => { setExpanded(true); setGroups(Object.fromEntries(files.map((file) => [file.phase, true]))); }
							}, `${count} ${count === 1 ? "archivo" : "archivos"}`),
							!active ? h(IconButton, { icon: "x", label: "Ocultar ejecución", disabled: busy, onClick: () => void act("dismiss") }) : null),
						h("div", { className: "dshwf-route-grid", id: routeId, hidden: !expanded, style: { "--dshwf-columns": Math.min(4, run.phases.length) }, onClick: (event) => {
							if (!event.target.closest("button") && !window.getSelection()?.toString()) { toggle.current?.focus(); setExpanded(false); }
						} },
							run.phases.map((p, i) => {
								const phaseFiles = files.filter((file) => file.phase === i);
								const status = phaseStatus(run, i);
								const label = groups[i] ? "Ocultar archivos" : `Ver ${phaseFiles.length} ${phaseFiles.length === 1 ? "archivo" : "archivos"}`;
								const listId = `${routeId}-files-${i}`;
								return h("div", { key: i, className: `dshwf-route-phase ${stateClass(i)}` },
									rail(i),
									h("div", { className: "dshwf-route-title", title: `${p.name} · ${statusLabel(i)}` }, status === "done" ? h(Icon, { name: "check", size: 12 }) : null, h("span", null, p.name)),
									phaseFiles.length ? h(Fragment, null,
										h("button", { type: "button", className: "dshwf-files-toggle", "aria-expanded": Boolean(groups[i]), "aria-controls": listId, "aria-label": `${label} de ${p.name}`, onClick: () => setGroups((value) => ({ ...value, [i]: !value[i] })) }, label),
										h("ul", { className: "dshwf-phase-files", id: listId, hidden: !groups[i] }, phaseFiles.map((file) => h("li", { key: file.path },
											h("button", { type: "button", className: "dshwf-artifact", title: file.path, "aria-label": `Abrir ${file.name}`, onClick: () => void read(file) }, h(Icon, { name: "file", size: 13 }), h("span", null, file.name)))))) : null,
									status !== "done" ? h("span", { className: "dshwf-route-status" }, statusLabel(i)) : null);
							})),
						prompt ? h("div", { className: `dshwf-bubble-prompt${run.state === "error" ? " dshwf-err" : ""}` }, h("span", null, prompt), action) : null,
						expanded ? h("div", { className: "dshwf-bubble-actions" },
							h("button", { type: "button", onClick: openPanel }, "Panel de workflows"),
							h("span", { className: "dshwf-spacer" }),
							active ? h(IconButton, { icon: "skip", label: "Saltar fase", disabled: busy, onClick: () => void act("skip") }) : null,
							active ? h(IconButton, { icon: "stop", label: "Detener workflow", disabled: busy, tone: "danger", onClick: () => void act("stop") }) : null) : null,
						error ? h("div", { className: "dshwf-err", role: "alert" }, error) : null,
						h("span", { className: "dshwf-sr", "aria-live": "polite" }, `${title}. ${active ? STATE_LABEL[run.state] ?? run.state : title}. ${count} archivos.`))));
		}

		function WorkflowButton({ openPanel }) {
			return h(IconButton, { icon: "route", label: "Workflows", size: 16, onClick: openPanel });
		}

		//#endregion
		//#region plugin

		const inject = ["slots", "sidebarRightTabs", "sidebarRight", "inputTriggers", "sessions"];
		function createWorkflowSource(ctx, stores) {
			const claim = (session, workflow) => ({
				name: workflow.name,
				token: `/${workflow.name} `,
				hint: "Escribe el primer mensaje del workflow",
				attachments: false,
				async submit(args, actx) {
					const current = ctx.sessions.sessionOf(actx);
					if (current?.sessionId !== session.sessionId) return { kind: "error", text: "La conversación ha cambiado" };
					try {
						await stores.act(current.sessionId, "submit", { workflowId: workflow.id, input: args });
						return { kind: "success" };
					} catch (error) {
						return { kind: "error", text: error.message };
					}
				}
			});
			const find = (token) => stores.library.get().workflows.find((w) => `/${w.name}` === token);
			const resolve = async (session, token, signal) => {
				if (ctx.sessions.subagentAddress(session.sessionId) !== undefined) return undefined;
				await stores.refreshLibrary();
				if (signal.aborted) throw new Error("Consulta cancelada");
				if (stores.library.get().error) throw new Error(stores.library.get().error);
				const workflow = find(token);
				return workflow ? claim(session, workflow) : undefined;
			};
			return {
				trigger: "/",
				name: "workflows",
				order: 1,
				showGroupTitle: false,
				async candidates(session, { query, signal, position }) {
					if (position === "inline") return [];
					if (ctx.sessions.subagentAddress(session.sessionId) !== undefined) return [];
					await stores.refreshLibrary();
					if (signal.aborted) return [];
					const library = stores.library.get();
					if (library.error) throw new Error(library.error);
					const search = query.trim().toLowerCase();
					return library.workflows
						.filter((w) => `${w.name} ${w.description ?? ""}`.toLowerCase().includes(search))
						.map((w) => ({ name: w.name, description: w.description, value: w.id, section: "Workflows", icon: WorkflowGlyph }));
				},
				onPick({ candidate, session }) {
					const workflow = stores.library.get().workflows.find((w) => w.id === candidate.value);
					return workflow ? { claim: claim(session, workflow) } : undefined;
				},
				matchSpace(session, token) {
					if (ctx.sessions.subagentAddress(session.sessionId) !== undefined) return undefined;
					const workflow = find(token);
					return workflow ? { claim: claim(session, workflow) } : undefined;
				},
				matchClaim: resolve,
				async matchEnter(session, line, signal, envelope) {
					const token = line.trim().split(/\s/u)[0];
					if (!token.startsWith("/")) return undefined;
					const command = await resolve(session, token, signal);
					if (!command) return undefined;
					if (envelope.attachments > 0) throw new Error("Los workflows no admiten adjuntos desde el input");
					return { claim: command };
				}
			};
		}

		function apply(ctx) {
			ctx.effect(() => installCss(), "dsh-workflows: estilos");
			const stores = createStores(createApi());
			// Same resource address and session-scoped navigation as DSH's file links.
			const openFile = (sessionId, path) => {
				const encode = (part) => encodeURIComponent(part).replace(/%3A/gi, ":");
				const normalized = path.replace(/\\/g, "/").replace(/^(?:\.\/)+/, "");
				const address = `dsh-resource://file/session/${encode(sessionId)}/${normalized.split("/").map(encode).join("/")}`;
				ctx.sidebarRight.openResourceIn(sessionId, address);
			};
			ctx.effect(() => ctx.inputTriggers.registerSource(createWorkflowSource(ctx, stores)), "dsh-workflows: slash");
			const openPanel = () => {
				try {
					ctx.sidebarRight.openTab(TAB_KIND);
				} catch {
					// sin conversación en pantalla
				}
			};
			ctx.effect(() => ctx.sidebarRightTabs.register({
				id: TAB_ID,
				kind: TAB_KIND,
				priority: "extension",
				keepMounted: true,
				title: () => "Workflows",
				guide: [{
					id: "workflows",
					order: 60,
					title: () => "Workflows",
					description: () => "Fases con su propio prompt, skills y modelo",
					icon: WorkflowGlyph
				}]
			}), "dsh-workflows: tipo de pestaña");
			ctx.slots.inject("sidebar.right.pane.tab", () => ctx.slots.register({
				name: "sidebar.right.pane.tab",
				key: TAB_ID,
				inject: () => ({ stores })
			}, WorkflowsTab));
			ctx.slots.inject("conversation.input.dock", () => ctx.slots.register({
				name: "conversation.input.dock",
				id: "dsh-workflows",
				order: -10,
				inject: () => ({ stores, openPanel, openFile })
			}, WorkflowDock));
			// The session header is hidden on the empty-session Hero.
			ctx.slots.inject("conversation.input.left", () => ctx.slots.register({
				name: "conversation.input.left",
				id: "dsh-workflows",
				order: 30,
				inject: () => ({ openPanel })
			}, WorkflowButton));
		}

		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

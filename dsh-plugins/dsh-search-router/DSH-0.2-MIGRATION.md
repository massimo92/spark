# Local DSH 0.2 compatibility repair

Based on the installed XGrin/dsh-search-router 0.3.0. Local version: 0.3.1-dsh02.3.

- Host settings use an exported volatile Config schema, with reads from live references.
- Browser settings use configForms and plugins.item.
- Browser credential reads use the current remote.credentials API.
- The existing provider adapters, Tavily key reference and DuckDuckGo fallback are preserved.
- Profile order is stored as a comma-separated string; advanced provider options remain supported.

The profile depends on this directory through a file: dependency. Updating the Harness retains the repair. A future Harness API change requires checking this compatibility layer before changing the declared peer range.

Validated: plugin startup; panel mount; credential status; Tavily 429 fallback; real search through the full DSH profile; real DuckDuckGo search; live settings mutation.

The Plugins item summary returns description text; its page renders the single settings panel. Regression: panel-check.mjs verifies the actual registered component for both views.

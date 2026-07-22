# spark ws research

Purpose: record the install/security decisions behind `spark ws` so the setup is auditable.

## Sources checked

- Vikunja install wizard: https://vikunja.io/install/
- Vikunja full install docs: https://vikunja.io/docs/installing/
- Vikunja backup docs: https://vikunja.io/docs/what-to-backup/
- Vikunja CLI docs: https://vikunja.io/docs/cli/
- Vikunja API docs: https://vikunja.io/docs/api-documentation/
- Vikunja Swagger/OpenAPI: https://try.vikunja.io/api/v1/docs.json
- Vikunja API v2 docs: https://vikunja.io/docs/api-v2/
- Vikunja bot users: https://vikunja.io/docs/bot-users/
- Vikunja n8n docs: https://vikunja.io/docs/n8n/
- Vikunja webhooks docs: https://vikunja.io/docs/webhooks/
- n8n Docker install docs: https://docs.n8n.io/hosting/installation/docker/
- n8n security env vars: https://docs.n8n.io/hosting/configuration/environment-variables/security/
- n8n nodes/community package env vars: https://docs.n8n.io/hosting/configuration/environment-variables/nodes/
- NemoClaw Hermes quickstart: https://docs.nvidia.com/nemoclaw/user-guide/hermes/get-started/quickstart
- NemoClaw inference options: https://docs.nvidia.com/nemoclaw/user-guide/hermes/inference/inference-options
- NemoHermes command reference: https://docs.nvidia.com/nemoclaw/user-guide/hermes/reference/commands
- NemoClaw messaging channels: https://docs.nvidia.com/nemoclaw/user-guide/hermes/manage-sandboxes/messaging-channels
- NemoClaw security best practices: https://docs.nvidia.com/nemoclaw/user-guide/hermes/security/best-practices
- OpenShell providers and credential injection: https://docs.nvidia.com/openshell/sandboxes/manage-providers
- OpenShell sandbox management: https://docs.nvidia.com/openshell/latest/sandboxes/manage-sandboxes
- OpenShell network policies: https://docs.nvidia.com/openshell/latest/sandboxes/policies
- Tailscale Serve CLI: https://tailscale.com/docs/reference/tailscale-cli/serve
- Tailscale Services: https://tailscale.com/docs/features/tailscale-services

## Install method decisions

- Vikunja supports binary, source build, Docker, distro packages, FreeBSD, Kubernetes, and Ansible. `spark ws` uses Docker Compose because the requested target is dockerized, repeatable, and easy to bind privately.
- Vikunja docs state SQLite is fine for personal use and PostgreSQL/MySQL fit multi-user setups. `spark ws` uses PostgreSQL.
- Vikunja CLI creates only the human account. Hermes uses a Vikunja 2.4+ bot user named `bot-hermes`, created through `POST /api/v2/user/bots`; no Hermes password or email is stored.
- Setup authenticates the human through self-hosted `/api/v1/login`, creates a bot-owned token through `POST /api/v2/tokens` with `owner_id` set to the bot ID, and rejects tokens for regular users or bots owned by another human.
- Bot ownership controls lifecycle, not project access. Setup shares every project the human can administer with `bot-hermes` as read/write, then compares the projects visible to the human and bot. Projects the human cannot share remain a manual action.
- Spark registers the bot token as a generic OpenShell provider, attaches it to the running `hermes` sandbox, and installs a Vikunja skill that uses direct `curl` calls. No MCP server or Electron client is involved.
- The sandbox reaches the loopback-only Vikunja service through a Spark-managed TCP bridge on `host.openshell.internal:3456`. OpenShell policy permits only `/usr/bin/curl` to use that REST endpoint.
- Vikunja n8n docs document a community node, but `spark ws` keeps community packages disabled by default and uses the generic HTTP/webhook path for the inactive scaffold.
- Vikunja webhooks docs document project/user webhook endpoints plus HMAC-SHA256 signatures with `X-Vikunja-Signature`; the future workflow scaffold stores a shared mention secret for that verification contract.
- n8n runs in Docker with PostgreSQL. `spark ws` uses the same Postgres service as Vikunja, but creates separate DBs/users to keep data ownership separate.
- n8n documents the security env vars used by the compose file: `N8N_BLOCK_ENV_ACCESS_IN_NODE`, `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES`, `N8N_RESTRICT_FILE_ACCESS_TO`, `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS`, `N8N_GIT_NODE_DISABLE_BARE_REPOS`, `N8N_GIT_NODE_ENABLE_HOOKS`, `N8N_SECURITY_POLICY_MANAGED_BY_ENV`, `N8N_PERSONAL_SPACE_PUBLISHING_ENABLED`, and `N8N_PERSONAL_SPACE_SHARING_ENABLED`.
- n8n community packages are disabled by default with `N8N_COMMUNITY_PACKAGES_ENABLED=false`, `N8N_UNVERIFIED_PACKAGES_ENABLED=false`, `N8N_VERIFIED_PACKAGES_ENABLED=false`, and `N8N_COMMUNITY_PACKAGES=[]`. Future Vikunja automation should use built-in HTTP/webhook nodes unless a reviewed package is explicitly enabled.
- n8n also documents `N8N_SECURE_COOKIE`. `spark ws` enables it for HTTPS Tailscale Services and disables it for HTTP MagicDNS ports mode.
- Hermes is installed through NemoClaw using `NEMOCLAW_AGENT=hermes` and `nemohermes onboard`. For LiteLLM, NemoClaw's custom OpenAI-compatible provider is the right route: `NEMOCLAW_PROVIDER=custom`, `NEMOCLAW_ENDPOINT_URL=http://127.0.0.1:4000/v1`, `NEMOCLAW_MODEL=<spark-selected-model>`, `NEMOCLAW_PREFERRED_API=openai-completions`, `COMPATIBLE_API_KEY=dummy`.
- NemoHermes documents `--control-ui-port`, `--yes`, and `--yes-i-accept-third-party-software` on `nemohermes onboard`, so `spark ws` can pin the Hermes dashboard port and run non-interactively.
- NemoHermes documents `CHAT_UI_URL` for headless remote dashboard access. `spark ws` sets it to the final Hermes URL: Services mode uses `https://hermes.<tailnet>.ts.net`; ports mode uses `http://<machine>.<tailnet>.ts.net:18789`.
- NemoHermes documents `nemohermes <name> doctor`; `spark ws doctor` runs it for sandbox `hermes` as direct evidence that Hermes is healthy under NemoClaw.

## Security decisions

- Tailscale Services are preferred for stable role-based names like `https://tasks.<tailnet>.ts.net`. They require Tailscale 1.86+, admin approval when needed, and tag-based host identity.
- If Tailscale is older than 1.86, `spark ws setup` attempts to update Tailscale before failing Services setup.
- If Services cannot be used, ports mode binds only to the host Tailscale IPv4 address and uses the machine MagicDNS name plus explicit ports.
- Localhost URLs are not a valid workspace access mode; missing tailnet/MagicDNS evidence marks setup incomplete.
- Tailscale Funnel is rejected. It is public internet exposure, not tailnet-only access.
- Compose services get scoped env files, `no-new-privileges`, bounded json-file logs, and no public `0.0.0.0` bindings in the default Services mode.
- The human Vikunja password is transient and only used in memory during setup. `spark ws doctor` fails if it is ever found in `secrets.env`.
- The Vikunja bot token is passed to `openshell provider create/update` through the command environment, not the process argument list. Hermes sees only an opaque placeholder; OpenShell substitutes the real token in the approved Authorization header.
- Secrets and env-backed inputs are single-line only, so malicious or accidental newlines cannot corrupt Compose env files.
- n8n is hardened by blocking env/file access from workflow nodes, excluding high-risk command/file nodes, and disabling community package installation by default.
- Compose services use `no-new-privileges`, init, graceful stop, process limits, and bounded logs as baseline runtime hardening without adding image-breaking privilege drops.
- MVP command surface stays small: `setup`, `status`, `doctor`, `logs`, `backup`, and `help`.
- GitHub, WhatsApp, and workflow authoring are phase 2. Vikunja token import and n8n owner bootstrap happen through rerunning `spark ws setup`.
- Active Tailscale Funnel is handled explicitly: setup can reset it with `--funnel-action reset`, show status interactively, or abort. `--check` only reports it.
- NemoClaw supplies deny-by-default controls across network, filesystem, process, gateway auth, and inference layers; `spark ws` keeps Hermes in the restricted policy tier.

## Integration decision

- Vikunja remains the source of truth for tasks.
- Hermes acts as `bot-hermes` through direct Vikunja REST calls. Activity is attributed to the bot, while project access is granted explicitly.
- n8n should only detect events/mentions and notify Hermes with IDs. It should not become the task source of truth.
- Direct Hermes task access is active. The n8n workflow scaffold remains inactive; event-driven workflows are intentionally deferred.

## Acceptance evidence

- `spark ws setup --check` must not mutate config/data.
- `spark ws doctor` must pass before considering the base workspace healthy.
- Doctor calls `/api/v1/user` from inside the Hermes sandbox and requires the response identity to be `bot-hermes`.
- `spark ws doctor --strict` must pass with pinned image refs once the base workspace is production-ready.
- `spark ws backup` and `spark ws backup --verify DIR` must pass before upgrade or destructive changes.

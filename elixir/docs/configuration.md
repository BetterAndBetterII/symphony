# Configuration Guide

Symphony Elixir is configured from three places:

1. CLI arguments passed to `./bin/symphony`
2. YAML front matter in `WORKFLOW.md`
3. Environment variables referenced from `WORKFLOW.md` or used as documented fallbacks

If you are setting Symphony up for the first time, start with these five knobs:

- `tracker.project_owner`
- `tracker.project_number`
- `workspace.root`
- `hooks.after_create`
- `codex.command`

## Quick Start

A practical GitHub Project setup looks like this:

```md
---
tracker:
  kind: github_project
  project_owner: your-org-or-user
  project_number: 1
  project_field_status: Status
  active_states: [Todo, Spec, In Progress, Rework, Merging]
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 4
codex:
  command: codex app-server
server:
  port: 4000
---

You are working on {{ issue.identifier }}.
```

Use the Markdown body after the front matter as the Codex prompt template. If you leave the body
blank, Symphony falls back to a minimal built-in prompt containing the issue identifier, title, and
body.

## CLI Settings

| Setting | Default | What it does |
| --- | --- | --- |
| positional `path-to-WORKFLOW.md` | `./WORKFLOW.md` | Selects the workflow file to load at startup. |
| `--i-understand-that-this-will-be-running-without-the-usual-guardrails` | required | Symphony refuses to start without this acknowledgement flag. |
| `--logs-root /path` | current working directory | Writes rotating logs to `<logs-root>/log/symphony.log`. |
| `--port <n>` | disabled | Starts the Phoenix dashboard/API and overrides `server.port`. Use `0` for an ephemeral local port. |

## Environment Resolution Rules

- Use `$VAR_NAME` inside `WORKFLOW.md` when you want Symphony to resolve a value from the
  environment.
- Legacy `env:VAR_NAME` syntax is not supported.
- If a `$VAR_NAME` resolves to an empty string, Symphony treats that value as missing.
- When `tracker.kind: github_project` and `tracker.api_key` is omitted, Symphony resolves GitHub auth with `gh auth token --hostname <tracker-host>`.
- Ambient `GITHUB_TOKEN` / `GH_TOKEN` values are ignored unless you reference them explicitly as `tracker.api_key: $GITHUB_TOKEN` or `tracker.api_key: $GH_TOKEN`.
- `tracker.project_owner` / `tracker.project_number` do not have ambient fallback env vars; configure them directly or with explicit `$VAR_NAME` references.
- `workspace.root` expands `~` and normalizes path-like values.
- `codex.command` stays a shell command string; any `$VAR_NAME` inside it is expanded later by the
  launched shell, not by Symphony's config loader.

Automatic fallback sources:

| Workflow field | Fallback source |
| --- | --- |
| `tracker.api_key` for GitHub | `gh auth token --hostname <tracker-host>` |
| `tracker.api_key` for Linear | `LINEAR_API_KEY` |
| `tracker.project_slug` | `LINEAR_PROJECT_SLUG` |
| `tracker.assignee` for GitHub | `GITHUB_ASSIGNEE`, `TRACKER_ASSIGNEE` |
| `tracker.assignee` for Linear | `LINEAR_ASSIGNEE`, `TRACKER_ASSIGNEE` |

## `WORKFLOW.md` Front Matter Reference

### `tracker`

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `tracker.kind` | none | yes | Supported values: `github_project`, `memory`, `linear` (deprecated). |
| `tracker.endpoint` | GitHub: `https://api.github.com/graphql`; Linear: `https://api.linear.app/graphql` | no | Override only if you need a custom GraphQL endpoint or proxy. |
| `tracker.api_key` | GitHub: `gh auth token --hostname <tracker-host>`; Linear: `LINEAR_API_KEY` | yes for GitHub/Linear dispatch | Accepts a literal token or `$VAR_NAME`. For GitHub, omit it to reuse the active `gh` login; for headless or CI runs, set an explicit `$GITHUB_TOKEN` / `$GH_TOKEN`. |
| `tracker.project_owner` | none | yes for GitHub | GitHub Project owner (org or user). Configure directly or with an explicit `$VAR_NAME` reference. |
| `tracker.project_number` | none | yes for GitHub | GitHub ProjectV2 number. Accepts an integer, a string integer, or a `$VAR_NAME` reference. Configure it directly or with an explicit `$VAR_NAME` reference. |
| `tracker.project_field_status` | `Status` | no | Single-select field used as `issue.state`. |
| `tracker.assignee` | unset | no | Optional routing filter. GitHub accepts one login, a comma-separated list of logins, or `me`. Linear accepts an assignee id or `me`. |
| `tracker.project_slug` | `LINEAR_PROJECT_SLUG` when unset | yes for Linear | Deprecated Linear-only project selector. |
| `tracker.active_states` | `Todo`, `In Progress` | no | Accepts a YAML list or a comma-separated string. |
| `tracker.terminal_states` | `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done` | no | Accepts a YAML list or a comma-separated string. |

### `polling`

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `polling.interval_ms` | `30000` | no | Poll cadence in milliseconds. Reloaded config affects future ticks. |

### `workspace`

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `workspace.root` | `<system-temp>/symphony_workspaces` | no | Workspace parent directory. `~` expands to the home directory. `$VAR_NAME` is resolved before path normalization. |

### `hooks`

All workspace hooks run with the workspace directory as `cwd`.

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `hooks.after_create` | unset | no | Runs only when Symphony creates a brand-new workspace. Failure aborts workspace creation. |
| `hooks.before_run` | unset | no | Runs before each agent attempt. Failure aborts that attempt. |
| `hooks.after_run` | unset | no | Runs after each agent attempt. Failure is logged and ignored. |
| `hooks.before_remove` | unset | no | Runs before workspace deletion. Failure is logged and ignored. |
| `hooks.timeout_ms` | `60000` | no | Shared timeout for every hook. Non-positive values fall back to the default. |

### `agent`

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `agent.max_concurrent_agents` | `10` | no | Global cap on simultaneously running issues. |
| `agent.max_turns` | `20` | no | Max back-to-back Codex turns in one agent session before returning control to the orchestrator. |
| `agent.max_retry_backoff_ms` | `300000` | no | Caps exponential retry backoff after failures. |
| `agent.max_concurrent_agents_by_state` | `{}` | no | Per-state concurrency overrides. State names are normalized with `trim + lowercase`; invalid or non-positive values are ignored. |

### `codex`

Symphony passes Codex-owned settings through to the targeted app-server version. Check your local
Codex schema if you need the exact accepted enum values.

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `codex.command` | `codex app-server` | yes for dispatch | Launched via `bash -lc` inside the workspace directory. |
| `codex.approval_policy` | `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}` | no | Conservative default that rejects interactive approval flows. |
| `codex.thread_sandbox` | `workspace-write` | no | Thread-level sandbox mode. |
| `codex.turn_sandbox_policy` | workspace-scoped `workspaceWrite` policy | no | Object-form sandbox policy for each turn. See the default payload below. |
| `codex.turn_timeout_ms` | `3600000` | no | Total turn timeout in milliseconds. |
| `codex.read_timeout_ms` | `5000` | no | Startup and sync request timeout. |
| `codex.stall_timeout_ms` | `300000` | no | Event inactivity timeout. Values `<= 0` disable stall detection. |

Default `turn_sandbox_policy`:

```json
{
  "type": "workspaceWrite",
  "writableRoots": ["<current issue workspace>"],
  "readOnlyAccess": {"type": "fullAccess"},
  "networkAccess": false,
  "excludeTmpdirEnvVar": false,
  "excludeSlashTmp": false
}
```

You can override `codex.turn_sandbox_policy` with any object accepted by your installed Codex
app-server.

### `observability`

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `observability.dashboard_enabled` | `true` | no | Controls the terminal status dashboard. This does not replace `server.port`; the web UI still depends on the HTTP server being enabled. |
| `observability.refresh_ms` | `1000` | no | Snapshot refresh cadence for observability updates. |
| `observability.render_interval_ms` | `16` | no | Minimum render interval for the terminal dashboard. |

### `server`

| Field | Default | Required | Notes |
| --- | --- | --- | --- |
| `server.port` | disabled | no | Starts the optional Phoenix HTTP server. Positive values bind that port; `0` asks the OS for an ephemeral port. CLI `--port` wins if both are set. |
| `server.host` | `127.0.0.1` | no | Bind host for the HTTP server. |

## Common Recipes

### Route work only to the current GitHub user

```yaml
tracker:
  assignee: me
```

### Cap one state more aggressively than the global limit

```yaml
agent:
  max_concurrent_agents: 10
  max_concurrent_agents_by_state:
    Spec: 1
    In Progress: 4
```

### Keep the web dashboard but silence the terminal dashboard

```yaml
observability:
  dashboard_enabled: false
server:
  port: 4000
```

## Failure Modes to Expect

- Missing `WORKFLOW.md`, invalid YAML front matter, or non-map front matter blocks startup and new
  dispatches until fixed.
- Missing GitHub or Linear auth blocks dispatch for those tracker kinds.
- For GitHub Projects, omitting `tracker.api_key` also requires a working `gh` installation plus a logged-in session with the scopes Symphony needs.
- Missing GitHub project identity (`project_owner` / `project_number`) or Linear project identity
  (`project_slug`) blocks dispatch.
- Blank `codex.command` is invalid.
- Invalid optional numeric and list-like values usually fall back to built-in defaults instead of
  crashing the service.

# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls GitHub Projects (ProjectV2) for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `github_graphql` tool so that repo
skills can make raw GitHub GraphQL calls (for example: comment updates, project field updates).

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Install GitHub CLI (`gh`) and log in with the scopes Symphony needs:
   `gh auth login --hostname github.com --scopes repo,project,read:org`.
   - For headless or CI runs, keep using an explicit token via `tracker.api_key: $GITHUB_TOKEN`.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `github` skills to your repo.
   - The `github` skill expects Symphony's `github_graphql` app-server tool for raw GitHub GraphQL
     operations such as comment editing or project field updates.
5. Customize the copied `WORKFLOW.md` file for your project.
   - Configure the GitHub Project owner + number, or let the first-run guided bootstrap pick/create a project for you when starting without a `WORKFLOW.md`.
   - Configure the Project field used as "status" (default: `Status`).
   - Ensure the Project field values match your expected states (for example: `Todo`, `In Progress`,
     `In Review`, `Merging`, `Done`, `Rework`).
6. Either install the packaged release (no Elixir/Mix required on the target host) or use the source workflow below for local development.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Install packaged release

For Linux x86_64 hosts, install the latest release into your user profile without Elixir or Mix:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterAndBetterII/symphony/main/scripts/install.sh | sh
```

To install a specific version instead of the latest release:

```bash
SYMPHONY_VERSION=0.1.0 curl -fsSL https://raw.githubusercontent.com/BetterAndBetterII/symphony/main/scripts/install.sh | sh
```

The installer places the user-facing `symphony` command in `${XDG_BIN_HOME:-$HOME/.local/bin}` and
keeps the versioned runtime payload under `${XDG_DATA_HOME:-$HOME/.local/share}/symphony/`.

## Run from source

```bash
git clone https://github.com/BetterAndBetterII/symphony
cd symphony/elixir
mise trust -y
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`. When that file is missing, interactive terminals offer a guided GitHub Project bootstrap that can pick or create a ProjectV2 board and choose Codex defaults; non-interactive runs still create the baseline template automatically. Passing an explicit path still requires that file to exist.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: github_project
  project_owner: "your-org-or-user"
  project_number: 1
  project_field_status: "Status"
workspace:
  root: "$SYMPHONY_WORKSPACE_ROOT"
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a GitHub issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- When `tracker.kind: github_project` and `tracker.api_key` is omitted, Symphony resolves GitHub auth via `gh auth token --hostname <tracker-host>`.
- The implicit `GITHUB_TOKEN` / `GH_TOKEN` fallback is no longer used. Keep env-backed auth explicit with `tracker.api_key: $GITHUB_TOKEN` (or `$GH_TOKEN`) when needed.
- `tracker.project_owner` / `tracker.project_number` should be configured directly in `WORKFLOW.md` or via explicit `$VAR` references; Symphony no longer reads ambient `GITHUB_PROJECT_OWNER` / `GITHUB_PROJECT_NUMBER` automatically.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $GITHUB_TOKEN
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If the default `./WORKFLOW.md` is missing, Symphony now offers a guided GitHub Project bootstrap on interactive TTYs and falls back to the baseline starter template in non-interactive runs. Missing explicit workflow paths or invalid YAML still halt startup until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

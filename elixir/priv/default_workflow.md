---
tracker:
  kind: github_project
  endpoint: https://api.github.com/graphql
  api_key: $GITHUB_TOKEN
  project_owner: $GITHUB_PROJECT_OWNER
  project_number: $GITHUB_PROJECT_NUMBER
  project_field_status: Status
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: untrusted
  thread_sandbox: workspace-write
server:
  port: 0
  host: 127.0.0.1
---

Customize these environment variables before running Symphony against your repo:

- `GITHUB_TOKEN`: GitHub token with access to the project and repository.
- `GITHUB_PROJECT_OWNER`: GitHub org or user that owns the ProjectV2 board.
- `GITHUB_PROJECT_NUMBER`: numeric ProjectV2 number.
- `SOURCE_REPO_URL`: repository clone URL used for new workspaces.
- `SYMPHONY_WORKSPACE_ROOT`: directory for local issue workspaces.

You are working on an issue from the configured tracker.

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

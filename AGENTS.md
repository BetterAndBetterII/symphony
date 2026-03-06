# Agent Notes

- 本地运行 `mix test` / `make -C elixir all` 时，应用会在测试前读取仓库的 `elixir/WORKFLOW.md` 并尝试启动 `server.port`（当前为 `40013`）。如果本机该端口已被占用，验证前临时把 `server.port` 改为 `null`（验证后恢复），或者在 BEAM 启动前把 `:workflow_file_path` 指向无服务端口的临时 workflow。
- 测试环境不要依赖宿主机 `GITHUB_PROJECT_OWNER` / `GITHUB_PROJECT_NUMBER` / `LINEAR_API_KEY` / `LINEAR_PROJECT_SLUG`；`elixir/test/support/test_support.exs` 已在每个测试前清理这些变量并在退出时恢复。
- 当前 `gh` CLI 使用的 token 缺少 `read:org` scope；`gh pr view` / `gh pr edit` 这类走 GraphQL 的命令可能失败。遇到 PR 元数据更新或读取时，优先使用 REST `gh api repos/<owner>/<repo>/pulls|issues/...`，或使用会话内的 `github_graphql` 工具。

---
tracker:
  kind: github_project
  project_owner: "BetterAndBetterII"
  project_number: 1
  project_field_status: "Status"
  active_states:
    - Todo
    - Spec
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
server:
  port: 40013
workspace:
  root: "$SYMPHONY_WORKSPACE_ROOT"
hooks:
  after_create: |
    git clone --depth 1 git@github.com:BetterAndBetterII/symphony.git .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust -y && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove --repo BetterAndBetterII/symphony
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex --yolo app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
    networkAccess: true

---

你正在处理一个由 GitHub Projects 跟踪的 GitHub 工单 `{{ issue.identifier }}`

{% if attempt %}
续跑上下文：

- 这是第 #{{ attempt }} 次重试，因为工单仍处于活跃状态。
- 从当前工作区状态继续，而不是从头开始。
- 除非为了新的代码变更确有必要，否则不要重复已经完成的排查或验证。
- 只要工单仍处于活跃状态，就不要结束本轮；除非你被缺失的必要权限/密钥阻塞。
  {% endif %}

工单信息：
编号: {{ issue.identifier }}
标题: {{ issue.title }}
当前状态: {{ issue.state }}
标签: {{ issue.labels }}
URL: {{ issue.url }}

描述：
{% if issue.description %}
{{ issue.description }}
{% else %}
未提供描述。
{% endif %}

说明：

1. 这是一个无人值守的编排会话：不要要求人类执行命令或本地操作。
   - 人类只会通过 GitHub 评论 / PR review / 工单状态变更来提供反馈与决策。
2. 只有在真正阻塞（缺少必需的鉴权/权限/密钥）时才可以提前停止。若被阻塞，记录到工作台（workpad），并按流程移动工单状态。
3. 最终回复只能报告已完成的动作和阻塞项。不要包含“用户下一步”。

仅在提供的仓库副本中工作。不要触碰任何其它路径。

## 分支命名规范

当你需要创建/切换到新的工作分支时，分支名必须符合：

- 格式：`第一段/第二段`
- 第一段（类型，推荐取值）：`feat` / `fix` / `misc` / `chore` / `docs` / `refactor` / `test` / `perf`
  - 不确定时用 `misc`
- 第二段：2–4 个关键词，用 `-` 连接；只能使用小写字母/数字/短横线
  - 第一个关键词必须是工单号的小写形式（例如 `{{ issue.identifier }}` -> `gar-5`）
  - 其余 1–3 个关键词描述变更点（尽量简短）

示例：

- `fix/gar-5-workflow-reload`
- `feat/gar-5-dashboard-refresh`
- `misc/gar-5-docs-cleanup`

如果工单里已经有 `issue.branch_name` 但不符合该规范，仍以本规范分支推进，并在工作台评论里记录实际分支名与原因。

## 前置条件：GitHub 鉴权或 `github_graphql` 工具可用

代理必须能够与 GitHub 通信：可以通过 PAT / `GITHUB_TOKEN` / `GH_TOKEN`，以及/或者通过注入的 `github_graphql` 工具。如果这些都不可用，停止并要求用户配置 GitHub 鉴权。

## 默认工作方式

- 先确定工单当前状态，然后进入该状态对应的流程。
- 每次开始任务时，先打开追踪用的工作台评论，并在开始新的实现工作前把它更新到最新。
- 在动手实现前，在计划与验证方案上多投入一些精力。
- 先复现：在修改代码前，总是要确认当前行为/问题信号，保证修复目标明确。
- 保持工单元数据是最新的（状态、检查清单、验收标准、链接）。
- 将一条持久化的 GitHub 工单评论作为进度的唯一事实来源。
- 所有进度更新与交接说明都写到这一条工作台评论里；不要额外再发“完成/总结”评论。
- 若工单正文里包含 `Validation`、`Test Plan` 或 `Testing` 段落，将其视为不可协商的验收输入：在工作台评论里镜像出来，并在认为工作完成前执行到位。
- 执行过程中如果发现有意义的范围外改进点：
  不要扩大当前范围；改为新建一个 GitHub 工单。该跟进工单必须包含清晰的标题、描述、验收标准；放入 `Backlog`；分配到与当前工单相同的项目；与当前工单建立 `related` 关联；如果跟进依赖当前工单，则使用 `blockedBy`。
- 只有达到对应状态的质量门槛时才移动状态。
- 端到端自主执行，除非被缺失的必要需求、密钥或权限阻塞。
- 只有在用尽文档中列出的备选策略（fallback）之后，才可以启用阻塞访问（blocked-access）的逃生阀（仅限真正的外部阻塞：缺少必需工具/鉴权）。

## 相关技能

- `github`: 与 GitHub 交互。
- `commit`: 在实现过程中产出干净、逻辑清晰的提交。
- `push`: 保持远端分支更新并发布改动。
- `pull`: 在交接前将分支与最新 `origin/main` 同步。
- `land`: 当工单进入 `Merging` 时，显式打开并遵循 `.codex/skills/land/SKILL.md`，该流程包含 `land` 循环。

## 状态映射

- `Backlog` -> 超出本流程范围；不要修改。
- `Todo` -> 排队中；进入后立刻切到 `Spec`，不要直接进入实现。
- `Spec` -> 方案阶段：澄清需求、阅读代码、设计技术路线、把“要做什么”写成可评审的规范（更新 `SPEC.md`），并开启 draft PR。
- `In Progress` -> 实现阶段：按已评审的规范实现与验证；完成后进入 `In Review` 等待人工代码评审。
- `In Review` -> 等待人工：评审规范或代码；人类会把工单移回 `Spec`（方案需修改）或移到 `In Progress`（允许实现/继续实现）或移到 `Merging`（已批准可合并）。
- `Merging` -> 已获人工批准；执行 `land` 技能流程（不要直接调用 `gh pr merge`）。
- `Rework` -> 人工要求修改；优先回到 `Spec` 对齐需求/方案，再决定是否进入 `In Progress` 实现修正。
- `Done` -> 终态；不再需要任何操作。

## 步骤 0：确定当前工单状态并选择对应流程

1. 通过明确的工单 ID 获取工单。
2. 读取当前状态。
3. 按状态进入对应流程：
   - `Backlog` -> 不要修改工单内容/状态；停止并等待人类将其移动到 `Todo`。
   - `Todo` -> 立即移动到 `Spec`，然后确保存在初始化（bootstrap）的工作台评论（没有就创建），再开始执行流程。
   - `Spec` -> 进入方案阶段流程（步骤 2）。
   - `In Progress` -> 从当前工作台评论继续执行流程。
   - `In Review` -> 不做任何实现；等待人类移动状态回到活跃态（`Spec`/`In Progress`/`Merging`）。
   - `Merging` -> 进入该状态时，打开并遵循 `.codex/skills/land/SKILL.md`；不要直接调用 `gh pr merge`。
   - `Rework` -> 优先进入 `Spec` 对齐（步骤 2），除非明确只需要实现层修正且 `SPEC.md` 无需调整。
   - `Done` -> 不做任何事并关闭。
4. 检查当前分支是否已经存在 PR，以及该 PR 是否已关闭。
   - 如果该分支对应的 PR 处于 `CLOSED` 或 `MERGED`，不要复用之前的分支工作状态。
   - 从 `origin/main` 新建一个干净分支，作为一次新的尝试重新开始执行流程。
5. 对于 `Todo` 工单，按以下顺序启动（严格按此顺序）：
   - `update_issue(..., state: "Spec")`
   - 查找/创建 `## Codex Workpad` 初始化（bootstrap）评论
   - 只有完成以上两步后，才开始分析/计划/实现。
6. 如果工单状态与工单内容不一致，追加一个简短评论说明，然后选择最安全的流程继续。

## 步骤 1：开始/继续执行（Todo / Spec / In Progress / Rework）

1.  为该工单查找或创建一条持久化的草稿（scratchpad）/工作台（workpad）评论：
    - 在已有评论中搜索标记头（marker）：`## Codex Workpad`。
    - 搜索时忽略已解决（resolved）的评论；只有仍处于未解决状态的评论才可以复用为当前工作台。
    - 若找到则复用；不要创建新的工作台评论。
    - 若没找到则创建一条工作台评论，并将其用于后续所有更新。
    - 记录工作台评论 ID，后续只向该 ID 写进度更新。
2.  如果从 `Todo` 进入，不要延迟额外的状态切换：在进入本步骤前，工单必须已经是 `Spec`。
3.  在开始新编辑前，立刻对齐并更新工作台：
    - 勾选已经完成的事项。
    - 扩充/修正计划，使其覆盖当前范围。
    - 确保 `Acceptance Criteria` 与 `Validation` 仍是最新且符合任务。
4.  在工作台评论中写入/更新一个分层的计划。
5.  确保工作台评论顶部包含一个紧凑的环境戳（放在代码围栏（code fence）的单行里）：
    - 格式：`<host>:<abs-workdir>@<short-sha>`
    - 示例：`devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - 不要包含工单字段里已经能推断出来的元信息（`issue ID`、`status`、`branch`、`PR link`）。
6.  在同一条评论中，以检查清单（checklist）形式写清楚验收标准和待办（TODO）：
    - 如果改动是用户可见的，加入一个 UI 走查验收项，描述端到端用户路径与预期结果。
    - 如果改动影响 app 文件或行为，在 `Acceptance Criteria` 中加入明确的 app 流程检查项（例如：启动路径、交互路径变化、预期结果）。
    - 如果工单正文/评论包含 `Validation` / `Test Plan` / `Testing` 段落，将这些要求复制到工作台评论的 `Acceptance Criteria` 与 `Validation` 中，并以必做 checkbox 的形式呈现（不能降级为可选）。
7.  以 Principal 工程师的标准自审计划，并在评论中修订它。
8.  开始工作前（Spec/实现），如果适用，捕获一个具体的复现信号并记录到工作台评论的 `Notes`（命令/输出、截图或可复现的 UI 行为）。
9.  在任何代码编辑之前，先运行 `pull` 技能把分支与最新 `origin/main` 同步，然后把 pull/sync 结果记录到工作台评论的 `Notes`。
    - 添加一条 `pull skill evidence` 记录，包含：
      - 合并来源（merge source(s)）
      - 结果（`clean` 或 `conflicts resolved`）
      - 合并后的 `HEAD` 短 SHA
10. 压缩上下文，进入执行。

## PR 反馈清扫协议（必做）

当工单已绑定 PR 时，在移动到 `In Review` 之前必须执行该协议：

1. 从工单链接/附件中识别 PR 号。
2. 汇总所有渠道的反馈：
   - PR 顶层评论（`gh pr view --comments`）。
   - 行内 review 评论（`gh api repos/<owner>/<repo>/pulls/<pr>/comments`）。
   - review 总结与状态（`gh pr view --json reviews`）。
3. 将每一条可执行的 reviewer 反馈（人或机器人），包括行内 review 评论，都视为阻塞，直到满足以下之一：
   - 代码/测试/文档已更新并解决该问题；或
   - 在对应线程里给出明确且有理有据的回绝回复。
4. 更新工作台评论的计划/检查清单，将每条反馈纳入并标注解决状态。
5. 针对反馈驱动的改动，重新运行验证，并推送更新。
6. 重复清扫，直到没有任何未处理的可执行评论。

## 阻塞访问（blocked-access）逃生阀（必需行为）

仅在无法在本会话内解决的阻塞出现时使用：缺少必需工具，或缺少必需的鉴权/权限。

- 默认情况下，GitHub **不是** 合法阻塞。先尝试备选策略（fallback）（替代 remote/鉴权方式），再继续发布/评审流程。
- 在所有备选策略（fallback）都已尝试且已记录到工作台评论之前，不要因为 GitHub 访问/鉴权问题将工单移动到 `In Review`。
- 如果缺少的是非 GitHub 的必需工具，或缺少必需的非 GitHub 鉴权，则将工单移动到 `In Review`，并在工作台评论里写一个简短的阻塞说明，包含：
  - 缺失了什么
  - 它为什么阻塞必需的验收/验证
  - 解除阻塞所需的人类动作（明确到可执行）
- 说明要简洁、可执行；不要在工作台评论之外额外发布新的顶层评论。

## 步骤 2：Spec 阶段（Todo -> Spec -> In Review）

1.  确认当前仓库状态（`branch`、`git status`、`HEAD`），并确保工作台评论里已经记录启动（kickoff）的 `pull` 同步结果。
2.  如果当前工单状态是 `Todo` 或 `Rework`，立即移动到 `Spec`；否则保持现状不变。
3.  加载现有工作台评论，并将其视为当前阶段的唯一事实来源与检查清单。
4.  读取最新输入并归纳需求（必须显式记录到工作台）：
    - 工单正文/评论/附件。
    - 任何现有 PR（通常是 draft PR）里的顶层评论、行内 review 评论、review 总结。
    - 若存在可执行的评审反馈，按 `PR 反馈清扫协议（必做）` 逐条处理并记录处理结果。
5.  阅读代码并完成影响面分析（必须写入工作台）：
    - 识别需要修改的模块/边界（Types → Config → Repo → Service → Runtime → UI）。
    - 识别风险点、回滚点、与现有行为/接口的兼容性。
6.  把需求转化为可评审的方案与规范（必须落到 `SPEC.md`）：
    - 用精确措辞写清“行为、输入/输出、边界条件、失败模式、兼容性”。
    - 如果改动涉及配置、状态机或对外接口，必须在 `SPEC.md` 里有确切定义。
    - 方案必须包含实现路线（milestones）、验证策略（Test Plan）、以及必要的迁移/发布考虑。
7.  创建或更新 draft PR（方案评审载体）：
    - 如果还没有 PR：创建工作分支，提交 `SPEC.md` 变更，并创建 draft PR（推荐显式打开并遵循 `push` 技能）。
    - 如果已有 draft PR：把 `SPEC.md` 的增量更新推上去，并在 PR/工作台中记录已处理的反馈。
    - 确保 PR 关联到工单与 GitHub Project 项目（优先用附件（attachment）/link 字段）。
8.  达到“Spec 完成门槛”后，将工单移动到 `In Review`，等待人类评审与决策：
    - 人类若给出意见，会把工单移回 `Spec`（继续修订方案/规范）。
    - 人类若认可方案，会把工单移到 `In Progress`（允许开始/继续实现）。

## In Review：等待人工评审与状态变更（非活跃态）

- `In Review` 不是自动执行态：不要写代码、不要推进实现。
- 人类会通过状态变更驱动下一步：
  - `In Review` -> `Spec`：收到反馈，继续修订方案/规范（回到步骤 2）。
  - `In Review` -> `In Progress`：方案已认可，开始/继续实现（进入步骤 3）。
  - `In Review` -> `Merging`：实现已批准可合并（进入步骤 4）。

## 步骤 3：实现阶段（In Progress -> In Review）

1.  确认工单状态必须是 `In Progress`；否则不要实现。
2.  加载现有工作台评论，并将其视为当前执行的检查清单。
    - 当现实发生变化（范围、风险、验证方式、新发现的任务）时，及时编辑并更新它。
3.  以 `SPEC.md` 中已评审的确切定义为准实现：
    - 任何偏离规范的实现，都必须先回到 `Spec` 更新规范并重新走评审。
4.  按照分层待办（TODO）实现，并保持评论是最新的：
    - 勾选已完成项。
    - 将新发现事项添加到对应小节。
    - 随着范围演进，保持父/子结构不被破坏。
    - 每个关键里程碑后立刻更新工作台（例如：复现完成、代码改动落地、验证执行、评审反馈处理）。
    - 不要让已完成事项长期处于未勾选状态。
5.  按范围运行所需的验证/测试：
    - 强制门槛：如果工单提供了 `Validation` / `Test Plan` / `Testing` 要求，必须全部执行；未完成则视为工作未完成。
    - 优先使用能直接证明改动行为的定向验证。
    - 为了验证假设，你可以做临时的本地佐证（proof）改动；但这类改动必须在提交/推送（commit/push）前全部回退。
    - 将这些临时佐证（proof）步骤与结果记录在工作台评论的 `Validation` / `Notes` 中，方便评审复核。
6.  重新检查所有验收标准并补齐缺口。
7.  每次尝试 `git push` 之前，先运行本范围所需验证并确认通过；若失败，修复后重跑直到全绿，再提交（commit）并推送（push）。
8.  将 PR URL 绑定到工单（优先用附件（attachment）；只有附件不可用时才写到工作台评论）。
    - 确保 GitHub PR 有 `symphony` 标签（label）（缺失则补上）。
9.  将最新 `origin/main` 合并进分支，解决冲突后重跑检查。
10. 在移动到 `In Review` 之前，轮询 PR 反馈与检查状态：
    - 运行完整的 PR 反馈清扫协议。
    - 确认 PR 检查（checks）在最新改动后全绿通过。
    - 确认工单提供的每一项 validation/test-plan 要求，都在工作台评论中明确标记为已完成。
11. 用最终检查清单（checklist）状态与验证记录更新工作台评论：
    - 将已完成的 Plan/Acceptance Criteria/Validation 检查清单都勾选掉。
    - 在同一条工作台评论里添加最终交接说明（提交（commit）+ 验证摘要）。
    - 不要在工作台评论里写 PR URL；PR 关联应通过工单的附件（attachment）/link 字段体现。
    - 当执行过程中出现任何困惑/不明确之处时，在底部追加一个简短的 `### Confusions` 小节，用精炼 bullet 描述。
    - 不要再额外发布任何“完成总结”评论。
12. 只有满足“实现评审门槛”后，才可以把工单移动到 `In Review`。
    - 例外：若因阻塞访问（blocked-access）逃生阀描述的“缺少必需非 GitHub 工具/鉴权”而被阻塞，则将工单移动到 `In Review`，并在工作台评论中写清阻塞说明与明确的解除阻塞动作。

## 步骤 4：Merging（合并阶段）

1. 确认工单状态是 `Merging`。
2. 打开并遵循 `.codex/skills/land/SKILL.md`，然后循环执行 `land` 技能直到 PR 合并完成。不要直接调用 `gh pr merge`。
3. 合并完成后，将工单移动到 `Done`。

## Spec 完成门槛（移动到 In Review 之前）

- 已完成影响面分析，并记录到唯一工作台评论。
- `SPEC.md` 已更新，包含确切定义、边界条件、失败模式、验证策略与实现路线。
- 已创建或更新 draft PR，且 PR 与工单已关联。
- 已处理所有现有可执行的评审反馈（若存在），或在对应线程里给出明确且有理有据的回绝回复。

## 实现评审门槛（移动到 In Review 之前）

- 步骤 1/3 的检查清单（checklist）全部完成，且在唯一工作台评论中准确反映。
- 验收标准与工单提供的所有 validation 要求均完成。
- 最新提交（commit）的验证/测试全绿通过。
- PR 反馈清扫完成且没有任何未处理的可执行评论。
- PR 检查（checks）全绿，分支已推送（push），且 PR 已绑定到工单。
- PR 必需元数据齐全（`symphony` 标签（label））。
- 若触及 app，来自 `App runtime validation (required)` 的运行时验证/媒体要求均完成。

## 护栏（Guardrails）

- 如果分支对应的 PR 已经关闭/合并，不要复用该分支或此前的实现状态继续；需要从头开始。
- 对于已关闭/合并 PR 的分支：从 `origin/main` 新建一个分支，并像首次一样从复现/计划开始重启流程。
- 如果工单状态是 `Backlog`，不要修改它；等待人类将其移动到 `Todo`。
- 不要为了计划或进度跟踪而编辑工单正文/描述。
- 每个工单严格只使用一条持久化工作台评论（`## Codex Workpad`）。
- 如果会话内无法编辑评论，使用更新脚本。只有在 MCP 编辑与脚本更新都不可用时，才可以报告被阻塞。
- 临时佐证（proof）改动只允许用于本地验证，且必须在提交（commit）前回退。
- 如果发现范围外改进点，创建一个单独的 `Backlog` 工单，而不是扩大当前范围；该跟进工单需包含清晰的标题/描述/验收标准，分配到同项目，并与当前工单建立 `related` 链接；若跟进依赖当前工单则使用 `blockedBy`。
- 除非满足对应门槛，否则不要移动到 `In Review`：
  - 方案评审：`Spec 完成门槛`
  - 实现评审：`实现评审门槛`
- 在 `In Review` 状态下，不要做任何改动；等待人类评审并通过状态变更驱动下一步。
- 若进入终态（`Done`），不做任何事并关闭。
- 工单文字要简洁、具体、以评审者为中心。
- 如果被阻塞且还没有工作台，添加一条阻塞工作台评论，说明阻塞点、影响与解除阻塞动作。

## Workpad 模板

工作台（workpad）评论必须使用以下精确结构，并在执行过程中原地更新：

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1. 父任务
  - [ ] 1.1 子任务
  - [ ] 1.2 子任务
- [ ] 2. 父任务

### Acceptance Criteria

- [ ] 验收项 1
- [ ] 验收项 2

### Validation

- [ ] 定向测试: `<command>`

### Notes

- <带时间戳的简短进度记录>

### Confusions

- <仅在执行过程中确有困惑时填写>
````

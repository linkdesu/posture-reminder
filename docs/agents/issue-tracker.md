# Issue 跟踪：GitHub

本仓库的 Issue 与规格以 GitHub issue 形式存在。所有操作使用 `gh` CLI。

**文档语言**：Issue、Spec、Ticket 一律使用中文编写与维护；仅代码标识符、日志 JSON 键名、Git 标签与 CLI 命令保留英文原名。

## 约定

- **创建 issue**：`gh issue create --title "..." --body "..."`。多行正文使用 heredoc。
- **读取 issue**：`gh issue view <number> --json number,title,body,labels,comments`。
- **列出 issue**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，并按需加上 `--label` 与 `--state` 过滤。
- **把 issue 设为父 issue 的子 issue**：`gh issue create --parent <parent> ...`，或事后执行 `gh issue edit <parent> --add-sub-issue <child>`（`gh` 2.94+）。较旧的 `gh`：`gh api --method POST repos/<owner>/<repo>/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`（使用数据库 id，见下方 **阻塞**）。若无法使用子 issue，在子 issue 正文顶部写 `Part of #<parent>`。
- **评论 issue**：`gh issue comment <number> --body "..."`
- **添加/移除标签**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **关闭**：`gh issue close <number> --comment "..."`

仓库从 `git remote -v` 推断；在克隆目录内运行 `gh` 时会自动完成。

## 将 PR 作为分流界面

**把 PR 作为请求入口：否。**（如果本仓库把外部 PR 当作功能请求，设为 `yes`；`/triage` 会读取此标记。）

设为 `yes` 后，PR 使用与 issue 相同的标签与状态，命令换成对应的 `gh pr`：

- **读取 PR**：`gh pr view <number> --comments`，用 `gh pr diff <number>` 查看差异。
- **列出待分流的外部 PR**：`gh api --paginate 'repos/{owner}/{repo}/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`。
- **评论 / 打标签 / 关闭**：`gh pr comment`、`gh pr edit --add-label`/`--remove-label`、`gh pr close`。

GitHub 的 issue 与 PR 共用一个编号空间，所以裸写的 `#42` 可能指任意一种：先用 `gh pr view 42` 解析，失败再回退到 `gh issue view 42`。

## 当技能要求“发布到 issue 跟踪器”时

创建一个 GitHub issue。

## 当技能要求“获取相关 ticket”时

按上文 **读取 issue** 的方法读取。

## 寻路操作（Wayfinder）

供 `/wayfinder` 使用。**地图**是一个 issue，**子** issue 是 ticket。

- **地图**：一个带 `wayfinder:map` 标签的 issue，正文承载“备注 / 至今决策 / 迷雾”三部分。`gh issue create --label wayfinder:map`。
- **子 ticket**：以 GitHub 子 issue 形式链接到地图（见 **把 issue 设为父 issue 的子 issue**）。若子 issue 未启用，把子项加入地图正文的任务列表，并在子 issue 正文顶部写 `Part of #<map>`。标签：`wayfinder:<type>`（`research`/`prototype`/`grilling`/`task`）。认领后，ticket 分配给负责推进的开发者。
- **阻塞**：使用 GitHub **原生 issue 依赖**，这是规范且 UI 可见的表示。用 `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>` 添加边，其中 `<blocker-db-id>` 是阻塞项的数值 **数据库 id**（`gh api repos/<owner>/<repo>/issues/<n> --jq .id`，**不是** `#number` 或 `node_id`）。GitHub 通过 `issue_dependencies_summary.blocked_by` 报告阻塞（只含未关闭的阻塞项，即实时门控）。若依赖功能不可用，回退到在子 issue 正文顶部写 `Blocked by: #<n>, #<n>`。当所有阻塞项都关闭时，ticket 解除阻塞。
- **边界查询**：列出地图下未关闭的子项（`gh issue list --state open`，限定在地图的子 issue / 任务列表内），排除存在未关闭阻塞项（`issue_dependencies_summary.blocked_by > 0`，或 `Blocked by` 行中有未关闭 issue）或已有 assignee 的项；按地图顺序取第一个。
- **认领**：`gh issue edit <n> --add-assignee @me`，这是本次会话的第一次写操作。
- **解决**：`gh issue comment <n> --body "<answer>"`，然后 `gh issue close <n>`，再把上下文指针（gist + 链接）追加到地图的“至今决策”中。

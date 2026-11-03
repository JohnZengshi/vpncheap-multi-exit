# 本地任务管理

- 每个功能使用 `.scratch/<feature>/`。
- 规格放在 `spec.md`。
- 每个任务单独存放于 `issues/<NN>-<slug>.md`，按依赖顺序编号。
- 任务使用 `Status:` 记录状态，名称见 `triage-labels.md`。
- 使用 `Blocked by:` 记录依赖；依赖完成后才能执行。
- 评论追加至任务文件的 `## Comments`。
- 技能要求“发布”时写入本地文件；要求“获取任务”时读取对应文件。
- 不向远程平台创建任务。

若使用 wayfinder：
- 决策地图存放于功能目录下的 `map.md`。
- 决策任务记录 `Type:`、`Status:` 与 `Blocked by:`。
- 领取标记为 `claimed`；解决后追加 `## Answer`，标记为
  `resolved`，并将结论与文件引用写回地图。

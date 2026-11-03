# 出口与代理池管理

## 身份与选择

出口 ID 标识逻辑出口，端口租约跟随该 ID。界面分别显示配置节点、实际节点、入口及托管池；自动备用只改变实际节点，不自动转移 Provider 绑定。旧配置无法恢复时显示待核对。

同一来源的快照与订阅引用合并；不同来源的同名节点保留短 ID。唯一端点可延续已有映射，仅名称相同不足以认领身份。历史映射歧义和实际节点占用会阻止新增选择。

普通选择仅控制出口启停。仍有绑定的出口不能取消，停用的 Provider 也受保护。保存和 Broker 执行前都会查询最新绑定；无法核验时保留现状。先在现有 9Router 管理方式中明确迁移或解除绑定，再调整出口。

## 同步与恢复

新托管池名称包含完整出口 ID；归属由 `runtime/9router-applied.json` 的出口与池 ID 确定。名称前缀或同名关系不能授权接管外部池。已有池不会随备用切换改名。

健康出口自动建池。出口尚未健康时不会强行建池；健康出口集合变化会触发补同步，失败后仍保留周期重试。页面区分保存、出口调整、池同步和失败；池测试时间与出口健康检查时间分别展示。池测试通过只说明该池入口的检测结果。

有绑定的历史池保留。历史入口不等于当前入口，同名也不自动迁移。明确迁移仍使用现有入口：

```powershell
pwsh -NoProfile -File scripts/9router-sync.ps1 -MigratePool '<old-pool-id>=<selected-port>'
```

迁移先测试目标、写入并回读绑定，再重新检查选择、Broker 实例、归属、端口监听和剩余绑定，满足条件才删除旧池。外部管理操作仍可能与本工具竞争，不构成分布式原子事务。

同步失败可在页面点击“重试代理池同步”，或运行：

```powershell
pwsh -NoProfile -File scripts/9router-sync.ps1
```

明确拒绝的创建请求可重试；请求结果不确定时，`pendingCreates` 保存创建意图。下次同步先核对远端唯一匹配，不盲目重复创建。若持续显示 `create-outcome-unknown` 且远端没有匹配，需要人工确认原请求已结束、核对远端与台账；备份台账后，只清除已确认未创建的目标意图，再重试。存在歧义时保留待核对状态。

地址修复先保存 `pendingRepairs`；响应丢失后按原池 ID、出口 ID 及目标地址对账。不要重置租约或清空全部台账处理冲突。

## 验证

隔离回归：

```powershell
Get-ChildItem scripts/tests/*-regression.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName; if ($LASTEXITCODE) { throw $_.Name } }
node --test scripts/tests/consistency-api.test.cjs
```

浏览器测试使用已有 Playwright 安装及 Edge，执行 `consistency-ui.spec.cjs`；真实页面只读验证使用 `consistency-live-ui.spec.cjs`。

以下脚本会在实际 9Router 创建专用验收池与测试连接，启动独立 Broker、Dashboard，调用真实接口验证取消保护、失败和恢复，并清理本轮对象。只在已授权真实写入验收时执行：

```powershell
pwsh -NoProfile -File scripts/tests/consistency-live-acceptance.ps1
```

默认专用端口为 39201、39280，要求生产环境至少有一个健康节点可复制其受保护配置。证据保存在 `runtime/acceptance/live-<run-id>/evidence.json`。9Router 创建接口会将新测试连接初始化为启用；脚本使用唯一无效测试密钥并立即停用，不更改业务连接。

本次没有实现固定公网 IP 检测、锁定或阻断。自动备用继续保留；稳定出口 ID 不构成 Claude 或其他 Provider 的固定 IP 保护。

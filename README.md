# VPNCheap 多出口

本项目是一个独立的概念验证工作区，用于把本机已安装的 VPNCheap 节点缓存转换为供
9Router 代理池使用的多个回环代理出口。

本仓库刻意与 `C:\Work\vpncheap-console` 分离，不会修改 VPNCheap 安装、
VPNCheap 应用状态或 9Router 数据库。

## 当前状态

已在本机 Windows 环境中完成可行性验证：

- 可从 DPAPI 绑定的节点目录中读取 59 个在线节点。
- 14 个 hysteria2 节点中有 13 个成功建立了健康的回环出口。
- 13 个健康出口均返回不同的公网出口 IP 哈希。
- 抽查的 5 个 anytls 节点在当前网络下均握手失败。
- 9Router 管理 API 的身份认证已完成只读验证。
- Supervisor/Worker 架构的 Broker 连续运行两个出口超过 1 小时，每 15 秒执行一次
  健康检查，每 5 分钟刷新一次节点目录。
- 杀掉一个 Worker 后只重启对应出口，另一个出口保持健康；替代 Worker 以新的 PID
  恢复健康。
- 9Router 适配器创建并测试了两个 strict、active 的代理池。
- 按操作者要求，未改动 Provider 绑定：`codex` 和 `claude` 仍使用原有的
  `vpncheap` 池，两个新池均未绑定连接。
- 在没有绑定映射的情况下重新运行规划器，两个池均报告为 `exists`，没有待执行的
  池变更或冲突。
- Broker 已安装为登录触发的计划任务，并配置了单实例、失败重启和 5 分钟看门狗。
- 原有的 `vpncheap` 池保持完整，并继续为两个 Provider 连接提供服务。

13 个出口的结论来自临时探测。长期运行的 Broker 目前验证到两个出口，更大规模测试
仍待完成。

## 架构

```text
VPNCheap app_state.json
  -> DpapiCipher.TryUnprotectBound
  -> 内存中的节点目录
  -> 根据节点 raw_outbound 生成最小 sing-box 配置
  -> singbox_new_service / singbox_start_service
  -> 每个节点对应一个 127.0.0.1:<port> mixed 入站
  -> 每个端口对应一个 9Router 代理池
  -> Provider 连接绑定到其中一个代理池
```

9Router 的每个代理池只有一个 `proxyUrl`。因此多个出口必须使用多个代理池，不能把
多个 URL 放进同一个池。

## 目录结构

- `FEASIBILITY.md`：结论、实测容量、部署限制和分阶段计划。
- `FEASIBILITY.zh-CN.md`：中文可行性说明与交付方案。
- `EVIDENCE.md`：证据记录、运行时观察和未知项。
- `docs/vpncheap-internals.md`：逆向分析得到的应用状态、配置和原生 API。
- `docs/architecture.md`：Broker 和 Worker 设计。
- `docs/9router-integration.md`：本地认证、代理池创建和绑定规划。
- `docs/delivery-plan.md`：接口、里程碑、验收和回滚。
- `docs/security-risks.md`：凭据、暴露面、账号和运维风险。
- `scripts/lib/vpncheap-state.ps1`：只读的 DPAPI 节点目录读取器。
- `scripts/inspect-managed-surface.ps1`：托管 API 接口探查。
- `scripts/recover-vpncheap-state.ps1`：脱敏后的节点目录摘要。
- `scripts/multiexit-probe.ps1`：临时多出口验证脚本。
- `scripts/broker.ps1`：负责 start/stop/status 和 Worker 重启的 Supervisor。
- `scripts/worker.ps1`：为单个出口运行一个原生 sing-box 服务和回环端口。
- `scripts/dashboard.ps1`：本地状态页和受保护的出口选择接口。
- `dashboard/`：用于出口、代理池、Provider 路由和出口配置的浏览器界面。
- `scripts/9router-plan.ps1`：只读的代理池和绑定规划。
- `scripts/9router-apply.ps1`：显式执行并记录日志的 9Router 应用入口。
- `scripts/9router-rollback.ps1`：回滚由本 Broker 创建的对象。
- `scripts/9router-inventory.ps1`：只读的 9Router 代理池和连接清单。
- `scripts/install-broker-task.ps1`：安装、启动或删除登录时运行 Broker 的计划任务。
- `scripts/read-9router-db.cjs`：只读的 SQLite 检查工具。

## 快速开始

```powershell
pwsh -NoProfile -File .\scripts\inspect-managed-surface.ps1
pwsh -NoProfile -File .\scripts\recover-vpncheap-state.ps1
pwsh -NoProfile -File .\scripts\multiexit-probe.ps1 -MaxNodes 2 -MaxAttempts 14 -Protocol hysteria2 -RequireDistinctExitIps
pwsh -NoProfile -File .\scripts\broker.ps1 -Action start -MaxExits 2
pwsh -NoProfile -File .\scripts\broker.ps1 -Action status
pwsh -NoProfile -File .\scripts\dashboard.ps1 -Action start
pwsh -NoProfile -File .\scripts\install-broker-task.ps1 -StartNow
pwsh -NoProfile -File .\scripts\9router-inventory.ps1 -ShowNames
```

## 单文件启动器

可构建一个嵌入 PowerShell 脚本和 Dashboard 静态资源的 Windows 单文件可执行程序：

```powershell
pwsh -NoProfile -File .\packaging\build-vpncheap.ps1
```

输出文件为 `dist\vpncheap.exe`，可在 CMD、PowerShell 和 Git Bash 中使用，并支持普通
命令行参数：

```text
vpncheap.exe restart
vpncheap.exe status
vpncheap.exe dashboard start
vpncheap.exe task remove
vpncheap.exe 9router inventory -ShowNames
vpncheap.exe run broker.ps1 -Action status
```

当 exe 位于仓库内时，会使用仓库中的脚本和 `runtime` 目录。复制到其他位置运行时，
会把内嵌脚本解包到 `%LOCALAPPDATA%\VPNCheapMultiExit`，并将运行状态保存在那里。
可通过 `VPNCHEAP_HOME` 指定其他状态目录。

目标主机仍需安装 PowerShell 7 和 VPNCheap。9Router 相关命令还需要本机安装
9Router。

Dashboard 监听 `http://127.0.0.1:39080/`。打开“配置出口”可修改并行出口数量或选择
具体节点。页面只写入 `runtime/exit-config.json`，运行中的 Broker 会在几秒内热加载。
“导出 IP”会下载当前出口节点与最近一次健康检查所得真实出口 IP 的 CSV；普通状态快照
仍然只包含出口 IP 哈希。
端口租约会绑定到节点哈希，因此取消勾选后再次勾选同一节点，仍会回到原来的回环端口，
并保留已有的 9Router 代理池绑定。

Broker 的 `run` 入口通过独占文件锁防止计划任务与手动启动同时运行。已有租约的端口
被占用时，页面显示“端口被占用”，每 15 秒重试原端口，不再自动换端口。不要删除
`runtime/port-leases.json` 来处理冲突；应先检查占用进程。`runtime/broker.lock` 文件
可以一直存在，是否持有文件句柄才代表 Broker 是否占用锁。

可运行 `pwsh -NoProfile -File .\scripts\tests\broker-regression.ps1` 验证重复启动、
端口占用和租约保持逻辑；测试使用独立临时目录，不操作正在运行的出口。

在“9Router 代理池”面板中，尚未创建代理池的出口会显示“创建代理池”按钮，面板标题栏
还提供“为 N 个出口创建”。此操作会调用受保护的 `POST /api/nine-router/pools` 接口
（请求体为 `{"ports":[39004]}`，要求同源并携带 `X-Exit-Control: 1`）。它只会为健康
出口创建或重新启用名为 `vpncheap-<node>`、`strictProxy=true` 的代理池，执行 9Router
池测试，并记录到 `runtime/9router-applied.json`。它不会修改 Provider 绑定，遇到
名称或端口冲突会返回 409。

使用 `-BindConnectionPool "<connection-id>=<pool-name>"` 为每个出口指定要绑定的连接。
`9router-plan.ps1` 只读；除非传入 `-Apply`，否则 `9router-apply.ps1` 仅做试运行。
Apply 只创建缺失的池、更新 strict/active 状态、测试选中的池、写入本地日志，并仅绑定
明确指定的连接。只有在检查规划结果中显示的当前绑定后，才应添加 `-AllowRebind`。

当前部署保持 Provider 绑定不变。如确实需要绑定连接，请先规划明确映射：

```powershell
pwsh -NoProfile -Command "& .\scripts\9router-plan.ps1 -BindConnectionPool @('<codex-connection-id>=vpncheap-HK-香港2-UDP','<claude-connection-id>=vpncheap-HK-香港3-UDP') -AllowRebind"
```

只有需要在本机使用真实出口 IP 时才添加 `-ShowExitIp`。默认不会输出节点地址、端口、
密码、UUID、订阅 URL、代理 URL 或 9Router token。

探测默认使用 `hysteria2`，这是在本机验证通过的协议。传入 `-Protocol ''` 可扫描所有
协议，传入 `-Protocol anytls` 可进行诊断。

## 默认安全约束

- `9router-plan.ps1` 为只读；除非传入 `-Apply`，`9router-apply.ps1` 仅做试运行。
- 在未明确连接 ID 和目标池并传入 `-AllowRebind` 时，绝不应重新绑定已有连接。
- 保留原有的 `vpncheap` 池并保持未绑定，除非已批准新的明确迁移。
- 监听地址仅绑定到 `127.0.0.1`。
- 不要将 `app_state.json`、DPAPI token 或解密后的节点 JSON 复制到其他机器或问题
  跟踪系统。
- 9Router 运行期间，不要写入其实时 SQLite 数据库。
- 不要对离线或缺少 `raw_outbound` 的节点运行探测或 Broker。

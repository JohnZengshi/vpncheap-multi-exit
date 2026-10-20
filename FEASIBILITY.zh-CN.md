# VPNCheap 多出口可行性方案

## 1. 结论

可行。VPNCheap 不需要部署到服务器，可以在当前 Windows 机器上做一个本地
broker，把多个节点分别暴露为 `127.0.0.1` 上的独立 mixed 代理端口，再接入
9Router 的多个 proxy pool。

本机实测结果：

- 从 DPAPI 绑定的节点缓存中读到 59 个在线节点。
- 协议分布：45 个 anytls，14 个 hysteria2。
- hysteria2 扫描 14 个节点，13 个建立成功。
- 13 个健康出口返回 13 个不同的公网出口 IP 哈希。
- 同一次运行中 13 个 loopback 监听同时存在。
- anytls 抽样 5 个全部握手失败，当前网络下不作为主路径。

这证明了“节点缓存 -> 最小 sing-box 配置 -> 本地端口 -> 公网出口”的完整
链路。

在临时探针之后，已经完成两出口常驻 broker 的验证：

- broker 从 2026-10-20T01:57Z 起连续运行超过 1 小时；
- 两个出口每 15 秒做一次健康检查，每 5 分钟刷新一次节点目录；
- 两个出口返回不同的公网出口 IP 哈希；
- 杀掉其中一个 worker 后，另一个出口保持健康，被杀的 worker 用新 PID
  在原端口恢复为 healthy；
- 运行目录中的状态和日志未出现节点地址、密码、完整代理 URL 或 9Router
  token；
- 9Router 适配器已于 2026-10-20 应用到线上：创建并测试了两个 strict pool，
  并分别绑定了一个明确指定的 connection；重复生成计划时两个 pool 和两个
  绑定都显示为 `exists`。

尚未完成的是 13 个出口同时常驻的持续并发压测、provider 限流/风控验证、
以及 9Router 多 connection 的实际流量分布压测。

## 2. VPNCheap 原理

### 2.1 节点缓存

VPNCheap 把账号节点目录保存在：

```text
C:\Users\<user>\AppData\Roaming\vpncheap\app_state.json
```

关键结构：

```text
xboard_node_catalogs_bound_v3
  Accounts
    <accountKey>
      UserId
      AccountGeneration
      PayloadToken
```

`PayloadToken` 是 DPAPI 加密后的 JSON 数组，绑定当前 Windows 用户和账号代际：

```text
vpncheap-node-cache|schema=<SchemaVersion>|type=catalog|account=<UserId>|generation=<AccountGeneration>
```

每个节点包含 `id`、`name`、`protocol`、`address`、`port`、`country_code`、
`groups`、`online` 和 `raw_outbound`。其中 `raw_outbound` 已经是完整的
sing-box outbound 对象，包含服务器、端口、密码、TLS、obfs 等字段。

### 2.2 客户端建链

正常路径大致是：

```text
XboardNode + SingBoxConfigOptions
  -> RuleSetService
  -> SingBoxConfigBuilder.Build()
  -> singbox_new_service(config)
  -> singbox_start_service(serviceId)
  -> 本地 mixed / tun 监听
```

`sing-box.dll` 暴露的 native API：

```text
singbox_get_version
singbox_get_last_error
singbox_free_string
singbox_new_service
singbox_start_service
singbox_close_service
```

一个进程可以同时运行多个 service，这正是多出口的基础。

### 2.3 为什么不用现成 Builder

`SingBoxConfigBuilder.Build()` 会解析 VPNCheap 自己的规则集路径，并可能拉取
远程规则集。离开安装目录后，规则集路径不可用，native service 会创建失败。

探针改用节点自带的 `raw_outbound`，生成最小配置：

- 一个 `127.0.0.1` 上的 `mixed` inbound；
- 一个节点 outbound；
- 一个 `direct` outbound；
- `route.final` 指向节点 outbound；
- 本地 UDP DNS；
- 不引用任何 rule-set。

这保留了传输能力，同时去掉了不必要的规则集依赖。

## 3. 目标架构

```text
VPNCheap app_state.json
  -> DPAPI 只读解密
  -> 内存中的节点目录
  -> 每个节点一份最小 sing-box 配置
  -> 每个节点一个 native sing-box service
  -> 127.0.0.1:39001..39999 mixed 端口
  -> 每个端口一个 9Router proxy pool
  -> provider connection 绑定 proxyPoolId
```

生产环境建议：

- 一个 supervisor 进程；
- 每个出口一个 worker 进程；
- 每个 worker 只拥有一个 native service 和一个端口；
- supervisor 负责端口分配、健康检查、隔离、重启和状态输出；
- 节点凭据只存在于 worker 内存和传给 native 库的配置中。

## 4. 实测结果

| 项目 | 结果 |
| --- | --- |
| 在线节点 | 59 |
| anytls / hysteria2 | 45 / 14 |
| hysteria2 健康出口 | 13 / 14 |
| 不同出口 IP 哈希 | 13 |
| 健康响应时间 | 约 0.2 到 3.4 秒 |
| anytls 抽样 | 0 / 5，全部 `EOF` 或连接关闭 |
| 9Router 未认证 API | HTTP 401 |
| 9Router 本地 CLI token | HTTP 200 |
| 常驻 broker 出口 | 2 个，同时 healthy |
| 连续健康运行 | 超过 60 分钟 |
| 健康检查间隔 | 15 秒 |
| 节点目录刷新 | 300 秒 |
| worker 故障隔离 | 杀 1 个，另 1 个保持 healthy |
| worker 自动恢复 | 新 PID，同端口恢复 healthy |
| 脱敏扫描 | 未命中地址、密码、代理 URL、token |
| 9Router 线上 apply | 创建 2 个 pool，均为 strict/active，测试通过 |
| 9Router 绑定 | `codex` -> 39001，`claude` -> 39002 |
| apply 幂等性 | 重复计划为 2 个 `exists` 和 2 个绑定 `exists` |

一个 hysteria2 出口的本地健康延迟在约 3.6 到 8.1 秒之间波动。9Router 的
pool test 使用 8 秒超时访问 `https://google.com/`，因此“健康但很慢”的端口
仍可能被判为 `error`。发布 pool 前应只选择延迟有明显余量的出口，并重新
探测一次。

复现命令：

```powershell
cd C:\Work\vpncheap-multi-exit
pwsh -NoProfile -File .\scripts\multiexit-probe.ps1 -MaxNodes 2 -MaxAttempts 14 -RequireDistinctExitIps
pwsh -NoProfile -File .\scripts\9router-inventory.ps1 -ShowNames
```

## 5. 9Router 接入

### 5.1 一池一地址

9Router 的 proxy pool 只有一个 `proxyUrl`。因此多出口必须是：

```text
pool-vpn-01 -> http://127.0.0.1:39001
pool-vpn-02 -> http://127.0.0.1:39002
pool-vpn-03 -> http://127.0.0.1:39003
```

连接通过 `providerSpecificData.proxyPoolId` 绑定到某一个 pool。若要并发使用
多个出口，需要多个 connection 分别绑定不同 pool。

需要注意：这不等于“每个请求自动轮询所有出口”。9Router 按自己的 connection
调度规则选路；请求级轮询需要额外的本地均衡器，或修改 9Router 的调度行为。

### 5.2 本地认证

管理 API 即使在 localhost 也需要认证。未认证请求返回 401。打包服务接受：

```text
x-9r-cli-token
```

其值由以下内容派生：

```text
sha256(machine-id + "9r-cli-auth" + auth/cli-secret).substring(0, 16)
```

broker 应只在内存中计算，不打印、不落盘、不放在命令行参数里。`cli-secret`
等同于本机管理员凭据，必须和 9Router 数据目录保持同一用户 ACL。

当前线上状态（只读观测）：

- 8 个 provider connection；
- 3 个 pool：原 `vpncheap`、`vpncheap-39001`、`vpncheap-39002`；
- 三个 pool 均为 active、`strictProxy=true`，test status 为 `active`；
- `codex` 绑定 `vpncheap-39001`，`claude` 绑定 `vpncheap-39002`；
- 原 `vpncheap` pool 保留但没有 connection 绑定，因此不参与当前连接选路。

`strictProxy=true` 是有意配置：绑定出口不可用时，请求应失败，而不是绕过
proxy 直接使用本机网络出口。适配器默认只读；改变已有绑定必须提供准确的
`connection-id=pool-name` 映射并显式传入 `-AllowRebind`。

broker 已安装为计划任务 `vpncheap-multi-exit-broker`：用户登录时自动启动，
后台运行，忽略重复实例，并在异常退出后自动重启。

### 5.3 应用顺序

1. 读取 pools 和 connections；
2. 默认只生成计划；
3. 每个健康端口对应一个 pool；同名同 URL 的 pool 复用，必要时更新
   strict/active 状态；
4. 显式 `-Apply` 后才创建或更新 pool；
5. 调用 pool test，确认 `active`；
6. 只绑定通过 `-BindConnectionPool` 明确指定的 connection；
7. 重新读取并输出脱敏 diff；
8. 把创建、更新和重绑记录到本地 journal，支持回滚。

禁止在 9Router 运行时直接写 SQLite。

## 6. 服务器部署

不能直接把当前方案搬到 Linux：

- DPAPI 绑定当前 Windows 用户；
- `sing-box.dll` 是 Windows 原生库；
- 复制 DPAPI 密文或解密后的节点凭据会改变凭据边界，也可能违反服务条款。

可行选项：

1. broker 和 9Router 同机 Windows 部署（推荐）；
2. broker 放在 Windows VM，9Router 通过 WireGuard 或 SSH 连接；
3. 重新实现服务端获取流程，并单独评估条款、设备限制和凭据管理。

不要将 `127.0.0.1` 上的 mixed 端口直接暴露公网；它没有认证。

## 7. 实施阶段

| 阶段 | 内容 | 估算 |
| --- | --- | --- |
| P0 | 传输验证、临时探针、证据 | 已完成 |
| P1 | worker-per-exit broker、健康检查、隔离、重启 | 已完成（2 出口验证） |
| P2 | 9Router 计划器、显式 apply、严格代理和绑定 | 已完成并线上应用；幂等性已验证 |
| P3 | 计划任务、防火墙审计、日志轮转、监控 | 计划任务已完成；其余未完成，1-2 天 |

## 8. 验收标准

- 两个出口同时健康，并返回不同公网 IP；
- 全部健康 hysteria2 节点可同时启动，目标至少 10 个；
- 杀掉一个 worker 不影响其他出口；
- 每个新 pool 测试为 `active`；
- 每个绑定 connection 的 `proxyPoolId` 正确；
- 连续运行 30 分钟无端口泄漏或进程孤儿；
- 日志和状态中不出现节点地址、密码、UUID、订阅 URL、完整代理 URL 或
  9Router token；
- apply 重复执行不产生重复 pool 或重复绑定；
- 回滚后原有 `vpncheap` pool 保留，两个 connection 恢复到原绑定。

## 9. 风险与回滚

主要风险：

- 节点轮换、过期或单节点握手失败；
- anytls 在当前网络不可用；
- 其他网络可能阻断 hysteria2 的 UDP/QUIC；
- 同一账号多连接触发速率、设备或风控限制；
- 9Router 的 connection 调度未必均匀使用所有 pool；
- 端口复用导致 pool 指向错误出口；
- 健康但延迟接近 8 秒的出口被 9Router pool test 判为 `error`；
- 13 个出口同时运行时的 provider 限流和本机资源占用尚未压测。

回滚步骤：

1. 停止 broker；
2. 读取 apply journal；
3. 只删除本 broker 创建的 pool；
4. 只解绑或删除本 broker 创建的 connection；
5. 重新读取 9Router 状态，确认原有 `vpncheap` pool 未被改动；
6. 清理本地状态和计划文件。

## 10. 相关文件

- `FEASIBILITY.md`：英文可行性结论与阶段。
- `EVIDENCE.md`：证据链、运行观测、未知项。
- `docs/vpncheap-internals.md`：VPNCheap 内部结构。
- `docs/architecture.md`：broker 与 worker 设计。
- `docs/9router-integration.md`：pool 与 connection 接入。
- `docs/delivery-plan.md`：接口、里程碑、验收、回滚。
- `docs/security-risks.md`：凭据与运行风险。

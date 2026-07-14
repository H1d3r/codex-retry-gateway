# 可叠加网关策略设计

状态：已批准
日期：2026-07-14
Tracking issue：https://github.com/nonononull/codex-retry-gateway/issues/26
依赖 PR：https://github.com/nonononull/codex-retry-gateway/pull/25

## 1. 背景

当前 gateway 把 reasoning 规则、流式命中动作、Capacity 重试和最终状态码放在同一组配置中。默认 `continuation_recovery` 与 `strict_502` 为了在流结束后判断 reasoning 命中，会先缓存完整 SSE，再决定透传、续写、内部重试或返回 502。

这保证了命中规则时不会先向客户端发出半截正常响应，但也意味着客户端看到的首字时间可能接近整轮完成时间。用户提供的样本中，首字约为 29 分 33 秒，总耗时约为 29 分 40 秒；现有落盘已经记录上游响应头、首 chunk、首个可见内容和总耗时，但代理主链没有请求超时控制。

本轮需要把以下能力拆成可叠加的独立策略：

1. reasoning 规则是否启用。
2. Capacity 错误如何处理。
3. 通用 HTTP 429 如何处理。
4. 首个有效输出和请求总耗时超限后如何处理。

任何组合都必须继续全量采集，不得因为关闭 reasoning 规则而放弃模型、effort、token、结构、时序、状态和重试样本。

## 2. 目标

1. 规则模式增加“不使用规则”，并在该模式下真正边收边透传流式响应。
2. Capacity、HTTP 429、响应超时与 reasoning 规则独立，可在任意规则模式下叠加。
3. reasoning、续写、Capacity、429、超时重试共用单个客户端请求的 `guard_retry_attempts` 预算。
4. 429 重试遵守 `Retry-After`，避免立即放大上游限流。
5. 超时动作在尚未向客户端发送响应时可以安全返回 502 或内部重试。
6. 已向客户端发送不可撤回内容后，不做会产生重复文字或重复工具调用的内部重试。
7. 保持现有默认 reasoning 行为、压缩豁免、516/518*n-2、final answer only、续写和配置恢复语义。
8. 所有新行为可热更新、可落盘、可导出、可在实时状态和日志中观察。

## 3. 非目标

1. 本轮不实现跨请求、跨用户或跨 provider 的真正断路器状态机。
2. 本轮“熔断重试”只表示终止当前慢上游尝试，并在当前客户端请求的预算内重新派发。
3. 不按模型、模型家族或 reasoning effort 自动推导超时阈值。
4. 不改变 Codex 自身的客户端重试行为。
5. 不把普通 5xx、所有网络错误或任意错误文本泛化成内部重试。
6. 不重构整个 `gateway.mjs` 文件结构，不引入第三方依赖。
7. 未经单独确认，不应用或重启实际运行在 `127.0.0.1:4610` 的 gateway。

## 4. 已确认口径

### 4.1 不使用规则

`intercept_rule_mode=none` 只关闭 reasoning 规则：

- 不判断 reasoning_tokens 或 final answer only 是否命中。
- 不触发 reasoning 普通内部重试。
- 不触发 Responses 续写恢复。
- 不因 `stream_action` 进入整段 SSE 缓冲。
- 不剥离或改写原始请求、响应中的 continuation 专用字段。
- 仍执行全量结构解析和详细落盘。
- Capacity、429 和响应超时仍按各自策略运行。

### 4.2 首个有效输出

以下事件可以结束首个有效输出计时：

- output text、commentary 或 final answer 的非空内容。
- tool/function call 已出现或开始产生参数。

以下事件不能结束首个有效输出计时：

- SSE 心跳、空白 chunk。
- `response.created`、`response.in_progress` 等生命周期事件。
- 模型名、fingerprint、service tier 等元数据。
- reasoning item、encrypted reasoning 或仅供网关内部判断的结构事件。

### 4.3 HTTP 429

gateway 应匹配每次上游 HTTP `429`，而不是匹配 Codex 在多次重试耗尽后生成的 `exceeded retry limit, last status: 429 Too Many Requests` 文案。

精确 Capacity 特征如果同时使用 HTTP 429，Capacity 策略优先；同一个上游响应只触发一个策略、只消耗一次重试预算。

## 5. 配置模型

### 5.1 Reasoning 规则模式

`intercept_rule_mode` 增加第三个值：

```text
reasoning_tokens
final_answer_only_high_xhigh
none
```

默认值继续是 `reasoning_tokens`。

### 5.2 上游错误动作

Capacity 与 HTTP 429 各自使用一个动作字段：

```json
{
  "capacity_error_action": "retry_then_pass_through",
  "http_429_action": "pass_through"
}
```

两个字段共享以下枚举：

```text
pass_through
return_502
retry_then_pass_through
retry_then_502
```

语义：

- `pass_through`：不做内部重试，原样返回上游状态与响应体。
- `return_502`：不做内部重试，转换为 gateway 502。
- `retry_then_pass_through`：有预算时内部重试，耗尽后原样返回上游响应。
- `retry_then_502`：有预算时内部重试，耗尽后转换为 gateway 502。

兼容迁移：

- 旧配置 `retry_upstream_capacity_errors=false` 映射为 `capacity_error_action=pass_through`。
- 旧配置 `retry_upstream_capacity_errors=true` 或缺失映射为 `capacity_error_action=retry_then_pass_through`。
- `http_429_action` 缺失时默认 `pass_through`，保持普通 429 原样透传。
- 兼容期继续读取旧布尔字段，但新动作字段是最终真源。

### 5.3 响应超时保护

```json
{
  "latency_guard": {
    "enabled": false,
    "first_progress_timeout_ms": 0,
    "first_progress_action": "return_502",
    "total_timeout_ms": 0
  }
}
```

约束：

- `enabled=false` 时不创建超时计时器。
- `0` 表示单独关闭该阈值。
- `enabled=true` 时至少一个阈值必须大于 0。
- 正数必须是安全整数。
- `first_progress_action` 只允许 `return_502` 或 `retry_then_502`。
- `total_timeout_ms` 是整个客户端请求跨内部重试的硬截止线；触发时已经没有剩余时间，因此始终直接进入 502 或已透传后的断连分支，不再开始新 attempt。
- 默认关闭，升级后不改变现有请求生命周期。

### 5.4 共享重试预算

`guard_retry_attempts` 继续表示单个客户端请求最多允许的内部追加尝试次数。以下动作共用同一个 `guardRetryAttemptsUsed`：

- reasoning 普通内部重试。
- Responses 续写恢复。
- Capacity 内部重试。
- HTTP 429 内部重试。
- 首个有效输出超时重试。

现有 `fetch failed` 的一次轻量连接重试保持原语义，不并入本轮策略枚举，也不扩大到其它错误。

## 6. 请求处理顺序

单次上游尝试按以下顺序收口：

1. 建立本次 attempt 样本和 AbortController。
2. 从第一次上游派发开始建立客户端请求总 deadline；内部重试不得重置总 deadline。
3. 每次 attempt 单独建立首个有效输出 deadline。
4. 如果计时器先触发，标记明确的 timeout phase 并中止当前 attempt。
5. 收到完整错误响应后，先判断精确 Capacity，再判断剩余通用 429。
6. 正常响应继续进入既有 reasoning 规则判断。
7. 没有任何策略接管时按原始上游响应透传。

策略优先级为：

```text
timeout > capacity > generic HTTP 429 > reasoning rule > pass through
```

优先级只用于避免一个响应重复处理，不表示后续请求不能命中其它策略。

## 7. 429 等待策略

1. 同时支持 `Retry-After: <seconds>` 和 HTTP-date。
2. 有合法 `Retry-After` 时按该值等待。
3. 没有合法 header 时使用 full-jitter 退避：`0..min(30000, 1000 * 2^retry_attempt_index)` 毫秒。
4. `Retry-After` 单次等待上限固定为 60 秒，不增加新的管理页配置。
5. `Retry-After` 超过 60 秒或超过请求剩余总 deadline 时，不提前轰击上游，直接执行当前动作的耗尽分支。
6. 所有等待必须可被客户端断开、总超时或 gateway 关闭中止。

## 8. 流式响应约束

### 8.1 Reasoning 规则开启

保留现有严格缓冲与续写行为：在决定 reasoning 命中前不向客户端发送不可撤回内容。因此 Capacity、429、超时和 reasoning 命中在返回头前均可安全重试或转换为 502。

### 8.2 不使用规则

默认边读取、边解析、边透传，不等待 `response.completed`。

如果启用了可能返回 502 或重试的 latency guard，则只允许暂存首个有效输出之前的 lifecycle/metadata 前导块：

- 首个有效输出到达时，先写上游响应头，再按原顺序刷出前导块和当前 chunk，随后进入直接透传。
- 首个有效输出超时发生时，丢弃未透传前导块，可以安全重试或返回 502。
- 前导块使用 1 MiB（1,048,576 bytes）固定内存上限；超过上限时必须开始透传并记录 `timeout_response_control_lost=true`，后续超时只能断开连接。
- 前导缓冲不改变用户可见首字时间，因为其中不包含有效文字或工具调用。

### 8.3 已透传后的限制

只要客户端响应头或不可撤回 chunk 已写出：

- 不能把状态改写成 502。
- 不能在同一响应中重新派发并拼接新一轮输出。
- 超时只能取消上游 reader、终止下游连接并写入明确样本。
- `final_action` 必须区分 `timeout_disconnected_after_forward`，不能伪装成返回 502。

## 9. 502 契约

新策略返回 502 时使用稳定响应头：

```text
x-codex-retry-gateway-reason: upstream-capacity
x-codex-retry-gateway-reason: upstream-rate-limited
x-codex-retry-gateway-reason: upstream-first-progress-timeout
x-codex-retry-gateway-reason: upstream-total-timeout
```

JSON 错误体包含：

- `error.type=codex_retry_gateway_upstream_policy_error`
- 稳定 `error.code`
- 人类可读 message。
- `retry_attempt_index`。
- `retry_attempts_used`。
- `retry_attempts_remaining`。
- timeout 场景的 `timeout_limit_ms` 与 `timeout_phase`。

不得把上游鉴权 header、token、完整请求体或 encrypted reasoning 写入错误体。

## 10. 采集与统计

reasoning 行为 schema 版本递增，并在每次 attempt 样本中补充：

```text
policy_trigger
policy_action
retry_trigger
retry_delay_ms
retry_after_raw
retry_after_ms
retry_budget_used
retry_budget_remaining
first_progress_at
first_progress_at_ms
time_to_first_progress_ms
client_headers_sent_at
client_headers_sent_at_ms
client_first_write_at
client_first_write_at_ms
time_to_client_first_write_ms
timeout_phase
timeout_limit_ms
timeout_response_control_lost
response_forwarding_started
```

保留现有：

- `upstream_wait_ms`
- `time_to_first_chunk_ms`
- `time_to_first_content_ms`
- `duration_total_ms`
- token、TPS、结构、模型、effort、HTTP 状态与失败摘要。

运行期增加分项计数：

- Capacity 触发、重试、透传、502。
- HTTP 429 触发、重试、透传、502。
- 首个有效输出超时。
- 总耗时超时。
- 超时重试。
- 超时 502。
- 已透传后超时断连。

JSON/CSV 导出必须包含新字段；旧样本缺字段时保持 `null`，不伪造数据。

## 11. 管理页

页面布局不做整体重构。

### 11.1 规则模式

把现有规则 radio 改为一个下拉框：

```text
reasoning_tokens 长度（推荐）
final answer only（实验，排除 0）
不使用规则（直接透传，仍采集）
```

选择“不使用规则”后：

- reasoning 命中来源、`reasoning_equals`、命中后流式动作和拦截范围进入禁用状态。
- Capacity、429、响应超时和重试次数保持可编辑。
- 当前生效策略明确显示“reasoning 直接透传 + 独立保护策略”。

### 11.2 上游错误策略

Capacity 与 HTTP 429 各使用一个紧凑下拉框，展示四个动作枚举。Capacity 文案注明精确匹配现有错误；429 文案注明匹配所有剩余上游 HTTP 429 并遵守 `Retry-After`。

### 11.3 响应超时

新增独立设置组：

- 启用响应超时保护。
- 首字/首个有效输出上限（ms）。
- 请求总耗时上限（ms）。
- 首个有效输出超时动作：直接 502 / 内部重试，耗尽后 502。
- 请求总耗时是硬截止线：未透传时直接 502，已透传时终止连接。

禁用时保留用户输入值但不生效；策略摘要展示实际生效阈值和共享重试次数。

## 12. 配置与启动兼容

必须同步以下控制面：

- `gateway.mjs` 默认值、load/save/热更新和日志。
- `scripts/admin-lib.mjs` Unix/Node 首装与复用迁移。
- `scripts/install-for-current-provider.ps1` Windows 首装配置。
- `scripts/launch-ui.ps1` Windows 复用迁移。
- `config.example.json`。

重点防止：

- Windows launch 把 `intercept_rule_mode=none` 重写回 `reasoning_tokens`。
- 新嵌套超时配置在复用启动时被丢弃。
- 正确配置被每次启动重复改写或导致无意义重启。
- 旧 `retry_upstream_capacity_errors` 迁移后改变耗尽行为。

`start`、`stop`、`restore` 只消费完整配置路径，不需要改变进程生命周期语义。

## 13. 测试矩阵

### 13.1 RED：规则与直接透传

- 配置 API 可保存并返回 `intercept_rule_mode=none`。
- 管理页下拉框包含三个模式，并在 none 下禁用 reasoning 专属控件。
- none + 流式正常响应在上游未完成前就能收到首个有效 chunk。
- none 模式仍生成完整 reasoning 行为样本。
- none 模式不触发 reasoning 重试、续写或 encrypted content 剥离。

### 13.2 RED：Capacity 与 429

- Capacity 四种动作分别符合透传、直接 502、重试后透传、重试后 502。
- Capacity + HTTP 429 同时命中时只执行 Capacity 策略。
- 普通 429 默认原样透传。
- 429 可重试恢复为 200。
- 429 耗尽后可原样透传或返回 502。
- `Retry-After: 0`、秒数和 HTTP-date 可解析。
- 过长 Retry-After 不会提前重试。
- 429 与 reasoning/续写共用预算，不会各自获得完整次数。

### 13.3 RED：超时

- 首个 lifecycle chunk 不结束 first progress timer。
- 非空文字、commentary、final answer、tool call 结束 first progress timer。
- 首个有效输出超时可直接 502。
- 首个有效输出超时可重试并恢复。
- 总 deadline 跨内部重试不重置。
- 总超时耗尽后返回 502。
- 总超时触发后不得再创建新 attempt。
- 已透传后总超时只断连，不重试、不追加第二轮输出。
- 非流式 body stall 可被总超时取消。
- timer、reader 和 AbortController 在所有成功/失败分支清理，无残留进程和悬挂句柄。

### 13.4 RED：迁移与回归

- 新装默认 reasoning 规则、Capacity 兼容动作、429 透传、latency guard 关闭。
- 旧 Capacity 布尔值按既有语义迁移。
- Windows install/launch 保留 none 和 latency guard。
- Unix install/launch 保留 none 和 latency guard。
- 既有 518*n-2、final-only、压缩 0 豁免、516、续写、capacity、fetch failed 测试继续通过。

## 14. 验证命令

```powershell
node .\scripts\test-gateway-e2e.mjs
node .\scripts\test-install-restore.mjs
node .\scripts\test-launch-ui.mjs
node .\scripts\test-launch-ui-unix.mjs
node --check .\gateway.mjs
node --check .\scripts\admin-lib.mjs
git diff --check
```

PowerShell 变更脚本继续执行 AST 解析。所有 E2E 使用临时目录和临时端口，不访问实际 `127.0.0.1:4610`。

## 15. 交付顺序

1. 固化本设计与实施计划。
2. 创建失败测试并保存 RED 证据。
3. 按最小范围实现配置和 none 模式。
4. 实现 Capacity/429 策略。
5. 实现 latency guard 与详细采集。
6. 完整回归并进行至少两名 reviewer 的同题独立审查。
7. 修复所有 Critical/Important，重新执行全量测试与复审。
8. 先合并依赖 PR #25，再让本 PR 对 `main` 只呈现本次改动。
9. PR 通过后合并；不在本轮自动应用真实 gateway。

# 可叠加网关策略实施计划

> **执行要求：** 使用 `superpowers:test-driven-development` 逐任务执行；最终使用 `superpowers:requesting-code-review` 做双 reviewer 整体审查。

**目标：** 增加真正的 reasoning 直接透传模式，并让 Capacity、HTTP 429、首个有效输出超时和请求总 deadline 在任意规则模式下独立叠加。

**架构：** 保留 `gateway.mjs` 的单进程代理结构，在现有 request/attempt 循环中增加小型策略状态与稳定结果对象。reasoning 匹配、上游错误分类和 latency guard 各自负责判断，共用 `guardRetryAttemptsUsed`；所有最终写回客户端的动作仍由当前 attempt 收口，避免重复写头和重复输出。

**技术栈：** Node.js ESM、原生 `fetch`/`AbortController`/HTTP、内嵌管理页、PowerShell 与 Node 启动脚本、现有无依赖 E2E。

## 全局约束

- 设计真源：`docs/plans/2026-07-14-layered-gateway-policies-design.md`。
- Tracking issue：`https://github.com/nonononull/codex-retry-gateway/issues/26`。
- 默认 `intercept_rule_mode=reasoning_tokens` 不变。
- 普通 HTTP 429 默认原样透传，latency guard 默认关闭。
- 旧 `retry_upstream_capacity_errors=true` 必须保持“重试，耗尽后原样透传”。
- 总 deadline 跨内部重试不重置，触发后不得创建新 attempt。
- 已向客户端发送不可撤回内容后不得重试或改写 502。
- 所有内部策略重试共用 `guard_retry_attempts`。
- 不泛化重试普通 5xx，不改变既有一次 `fetch failed` 轻量重试。
- 不访问、重启或替换实际 `127.0.0.1:4610` gateway。

---

### Task 1：配置契约与管理页第三规则模式

**文件：**

- 修改：`scripts/test-gateway-e2e.mjs`
- 修改：`scripts/test-install-restore.mjs`
- 修改：`gateway.mjs`
- 修改：`config.example.json`

**接口：**

- `intercept_rule_mode` 新值：`none`。
- `capacity_error_action`：四值上游错误动作枚举。
- `http_429_action`：四值上游错误动作枚举。
- `latency_guard`：`enabled`、`first_progress_timeout_ms`、`first_progress_action`、`total_timeout_ms`。
- 新增纯归一化函数：`normalizeUpstreamErrorAction()`、`normalizeLatencyGuardConfig()`。

- [x] **Step 1：写配置与 UI RED 测试**

在 `test-gateway-e2e.mjs` 增加断言：

```js
assert(uiHtml.includes('<option value="none">'), "规则模式缺少不使用规则选项");
assert(savedPayload.intercept_rule_mode === "none", "管理页未提交 none 模式");
assert(savedPayload.capacity_error_action === "retry_then_502", "管理页未提交 Capacity 动作");
assert(savedPayload.http_429_action === "retry_then_502", "管理页未提交 429 动作");
assert(savedPayload.latency_guard?.first_progress_timeout_ms === 1500, "管理页未提交首输出阈值");
```

在 `test-install-restore.mjs` 增加默认值、配置 API 持久化与非法值拒绝断言。

- [x] **Step 2：运行 RED**

运行：

```powershell
node .\scripts\test-gateway-e2e.mjs
node .\scripts\test-install-restore.mjs
```

预期：因 `none`、动作字段和 `latency_guard` 尚不存在而失败，不允许因测试语法或端口问题失败。

- [x] **Step 3：实现最小配置归一化**

在 `gateway.mjs` 增加常量：

```js
const INTERCEPT_RULE_MODE_NONE = "none";
const UPSTREAM_ERROR_ACTION_PASS_THROUGH = "pass_through";
const UPSTREAM_ERROR_ACTION_RETURN_502 = "return_502";
const UPSTREAM_ERROR_ACTION_RETRY_THEN_PASS_THROUGH = "retry_then_pass_through";
const UPSTREAM_ERROR_ACTION_RETRY_THEN_502 = "retry_then_502";
const FIRST_PROGRESS_ACTION_RETURN_502 = "return_502";
const FIRST_PROGRESS_ACTION_RETRY_THEN_502 = "retry_then_502";
```

`loadConfig()` 与 `buildEditableConfig()` 必须共同使用同一归一化函数。非法正整数、非法枚举、启用 latency guard 却两个阈值均为 0 时，配置 API 返回 400。

- [x] **Step 4：实现管理页下拉框和禁用态**

将规则 radio 改为 `interceptRuleModeSelect`。选择 `none` 时禁用 reasoning match、reasoning equals、stream action 与拦截范围；Capacity、429、latency guard 和重试次数保持可编辑。策略摘要必须展示所有已启用策略。

- [x] **Step 5：运行 GREEN 与语法检查**

```powershell
node .\scripts\test-gateway-e2e.mjs
node .\scripts\test-install-restore.mjs
node --check .\gateway.mjs
git diff --check
```

- [x] **Step 6：提交 Task 1**

```powershell
git add gateway.mjs config.example.json scripts/test-gateway-e2e.mjs scripts/test-install-restore.mjs
git commit -m "feat: add layered gateway policy config"
```

提交：`b1609ad`

### Task 2：真正直接流式透传与时序采集

**文件：**

- 修改：`scripts/test-gateway-e2e.mjs`
- 修改：`gateway.mjs`

**接口：**

- `buildInterceptRuleMatch()` 在 `none` 下稳定返回 `matched=false`。
- `payloadHasMeaningfulProgress(payload)` 识别非空文字、commentary、final answer 与 tool/function call。
- `markReasoningSampleFirstProgress()` 只写第一次有效输出时间。
- `shouldStripEncryptedContentFromContinuationResponse()` 在 `none` 下必须返回 false。

- [x] **Step 1：写直接透传 RED 测试**

扩展 mock SSE，使其可在首个有效 chunk 后延迟 completed。发起 `intercept_rule_mode=none` 请求，使用流式 reader 断言：

```js
assert(firstChunkAt < upstreamCompletedAt, "none 模式仍在等待完整 SSE");
assert(sample.final_action === "passed", "none 模式样本未正常收口");
assert(sample.time_to_first_progress_ms !== null, "none 模式未采集首个有效输出");
```

同时断言 none 模式不触发续写、不删除 encrypted content、不产生 reasoning match。

- [x] **Step 2：运行 RED**

```powershell
node .\scripts\test-gateway-e2e.mjs
```

预期：客户端首个 chunk 仍在完整流结束后才到达，或 none 被归一化回旧模式。

- [x] **Step 3：实现 side-band 观察式透传**

`handleStreaming()` 根据 `intercept_rule_mode=none` 关闭 strict 全量缓冲，但继续解析 SSE、模型、usage、结构和时序。所有写头统一经过单次 helper，并把 `client_headers_sent_at_ms`、`client_first_write_at_ms`、`response_forwarding_started` 写入样本。

- [x] **Step 4：实现首个有效输出语义**

生命周期、心跳、元数据和 encrypted reasoning 不调用 `markReasoningSampleFirstProgress()`；非空 text/commentary/final 与 tool/function call 调用。保留现有 `first_content`，新增字段不能替换旧字段。

- [x] **Step 5：运行 GREEN**

```powershell
node .\scripts\test-gateway-e2e.mjs
node --check .\gateway.mjs
```

- [x] **Step 6：提交 Task 2**

```powershell
git add gateway.mjs scripts/test-gateway-e2e.mjs
git commit -m "feat: stream directly when reasoning rules are disabled"
```

提交：`d7573f0`

### Task 3：Capacity 与通用 HTTP 429 策略

**文件：**

- 修改：`scripts/test-gateway-e2e.mjs`
- 修改：`gateway.mjs`

**接口：**

- `classifyUpstreamErrorPolicy(config, upstreamResponse, parsedPayload, bodyBuffer)`。
- `parseRetryAfterMs(rawValue, nowMs)` 同时支持秒数与 HTTP-date。
- `buildUpstreamPolicyErrorBody()` 生成稳定、无敏感信息的 502。
- handler 返回 `{ policyRetry, retryReason, retryDelayMs }`，由 `proxyRequest()` 唯一扣减共享预算。

- [x] **Step 1：写 Capacity 四动作与 429 RED 测试**

mock upstream 支持按 attempt 返回 Capacity、通用 429、`Retry-After` 与恢复 200。逐项断言：

```text
pass_through -> 原始 status/body
return_502 -> 502 + 稳定 reason header
retry_then_pass_through -> 尝试耗尽后原始 status/body
retry_then_502 -> 尝试耗尽后 502
```

再断言 Capacity+429 只执行 Capacity，普通 429 默认不重试，429 与 reasoning 共用预算。

- [x] **Step 2：运行 RED**

```powershell
node .\scripts\test-gateway-e2e.mjs
```

预期：当前 Capacity 仅支持布尔重试并在耗尽后透传，通用 429 不受控。

- [x] **Step 3：实现错误分类与稳定动作**

精确 Capacity 优先。只有未命中 Capacity 的 HTTP 429 才进入 `http_429_action`。`return_502` 和 `retry_then_502` 使用不同稳定 reason/code；原样透传必须保留上游 status/body。

- [x] **Step 4：实现 Retry-After 与可中止等待**

合法 header 按值等待；超过 60 秒直接走耗尽分支。无 header 使用 `0..min(30000, 1000 * 2^attemptIndex)` full-jitter。等待计入总 deadline，并可被客户端断开或总 deadline 取消。

- [x] **Step 5：运行 GREEN**

```powershell
node .\scripts\test-gateway-e2e.mjs
node --check .\gateway.mjs
```

- [x] **Step 6：提交 Task 3**

```powershell
git add gateway.mjs scripts/test-gateway-e2e.mjs
git commit -m "feat: add capacity and rate-limit policies"
```

提交：`2644884`

### Task 4：首输出超时与总 deadline

**文件：**

- 修改：`scripts/test-gateway-e2e.mjs`
- 修改：`gateway.mjs`

**接口：**

- `createAttemptLatencyGuard()`：管理首 progress timer、剩余总 deadline、timeout phase 和清理。
- `PRE_PROGRESS_BUFFER_LIMIT_BYTES = 1024 * 1024`。
- handler timeout 结果只描述事实；`proxyRequest()` 决定重试、502 或已透传后断连。

- [x] **Step 1：写首 progress RED 测试**

mock SSE 支持延迟首 chunk、先 lifecycle 后 text、先 tool call 后 text。断言 lifecycle 不结束计时，tool call 与非空 text 会结束计时；超时可直接 502 或按共享预算重试恢复。

- [x] **Step 2：写总 deadline 与已透传 RED 测试**

断言：

- 总 deadline 从第一次上游派发开始，重试不重置。
- 总 deadline 触发后不会产生额外 attempt。
- 未透传时返回 `upstream-total-timeout` 502。
- 已透传后只断连，不重试、不追加第二轮输出。
- 非流式 body stall 可被总 deadline 取消。
- 请求结束后没有未清理 timer 或临时 gateway 进程。

- [x] **Step 3：运行 RED**

```powershell
node .\scripts\test-gateway-e2e.mjs
```

预期：慢响应继续无限等待，或 AbortError 被误记成普通 stream terminated。

- [x] **Step 4：实现 attempt latency guard**

timer 回调必须先设置明确 `timeoutPhase`，再 `abortController.abort()`。`handleStreaming()` 遇到 AbortError 时先检查 timeout state，不能把策略超时收口成普通上游断流。

none 模式在启用 latency guard 时只缓存首 progress 前导块；到达 1 MiB 后开始透传并写 `timeout_response_control_lost=true`。首 progress 后清理对应 timer；所有分支在 `finally` 清理剩余 timer、reader 和监听器。

- [x] **Step 5：补详细落盘与实时计数**

按设计第 10 节补 attempt 字段、`final_action`、JSON/CSV 字段和运行期 Capacity/429/timeout 计数。旧样本缺字段时返回 null。

- [x] **Step 6：运行 GREEN**

```powershell
node .\scripts\test-gateway-e2e.mjs
node --check .\gateway.mjs
```

- [x] **Step 7：提交 Task 4**

```powershell
git add gateway.mjs scripts/test-gateway-e2e.mjs
git commit -m "feat: enforce first-output and total response deadlines"
```

提交：`150241b`

### Task 5：Windows/Unix 配置迁移

**文件：**

- 修改：`scripts/test-install-restore.mjs`
- 修改：`scripts/test-launch-ui.mjs`
- 修改：`scripts/test-launch-ui-unix.mjs`
- 修改：`scripts/admin-lib.mjs`
- 修改：`scripts/common.ps1`
- 修改：`scripts/install-for-current-provider.ps1`
- 修改：`scripts/launch-ui.ps1`

**接口：**

- Windows 与 Unix 必须使用相同默认动作和 latency guard 约束。
- 已存在的 `none`、动作枚举和 latency guard 必须在 reuse 启动后逐字段保持。

- [x] **Step 1：写迁移 RED 测试**

四组场景：首次安装、旧 Capacity 布尔迁移、none 配置复用、嵌套 latency guard 复用。Windows/Unix 均断言配置内容和是否发生无意义重启。

- [x] **Step 2：运行 RED**

```powershell
node .\scripts\test-install-restore.mjs
node .\scripts\test-launch-ui.mjs
node .\scripts\test-launch-ui-unix.mjs
```

预期：现有 PowerShell/Node normalizer 把 none 改回 reasoning_tokens 或缺少新字段。

- [x] **Step 3：实现最小迁移**

`admin-lib.mjs` 和两个 PowerShell 控制面都只补缺失/非法字段；合法 none 与 latency guard 不重写。旧 Capacity 布尔按设计映射，正确配置二次启动保持零配置写入、零重启。

- [x] **Step 4：运行 GREEN 与 PowerShell AST**

```powershell
node .\scripts\test-install-restore.mjs
node .\scripts\test-launch-ui.mjs
node .\scripts\test-launch-ui-unix.mjs
node --check .\scripts\admin-lib.mjs
```

再对 `install-for-current-provider.ps1` 与 `launch-ui.ps1` 执行 PowerShell Parser AST 检查。

- [x] **Step 5：提交 Task 5**

```powershell
git add scripts/admin-lib.mjs scripts/common.ps1 scripts/install-for-current-provider.ps1 scripts/launch-ui.ps1 scripts/test-install-restore.mjs scripts/test-launch-ui.mjs scripts/test-launch-ui-unix.mjs
git commit -m "feat: migrate layered policy configuration"
```

提交：`4480e21`

### Task 6：文档、完整验证、双 reviewer 与 GitHub 交付

**文件：**

- 修改：`README.md`
- 修改：`build.md`
- 修改：`err.md`
- 修改：`docs/plans/sessions/crg-layered-gateway-policies.md`
- 修改：`.ai-growth-os/runtime-workflows/crg-layered-gateway-policies.yml`

- [x] **Step 1：更新用户与排错文档**

README 写清组合语义、默认值、已透传后的 HTTP 限制和 429 `Retry-After`。`build.md` 增加策略验收口径。`err.md` 记录 strict 全流缓冲造成首字接近完成时间的根因、修复边界和防回归命令。

- [x] **Reviewer 修复：补齐状态机边界与对应 E2E**

第一轮已按 RED/GREEN 补齐：Retry-After 等待中的总 deadline 502、客户端断连独立收口、已写响应禁止重试/502、非 JSON 流式 Capacity/429、首 progress 前断流保留前导块与响应头、空 commentary 不算 progress、endpoints 完整旁路、Node timer 最大值、非对象 latency 配置拒绝，以及严格 1 MiB 前导缓冲上限。

第二轮 reviewer 的 7 个 Important 也已逐项 RED/GREEN：Capacity 429 遵守正值 Retry-After、等待 timer 恢复后墙钟复核总 deadline、SSE LF/CR/CRLF 混合边界、observe-only timeout 保留命中事实、误标 Content-Type 的 JSON SSE 有界识别、parser 状态拼接前执行 1 MiB 硬限制、严格保护下超大事件返回专用 `response_inspection_limit_exceeded` 502。当前状态为“修复已 fresh 验证、待原 reviewer 再复审”。

第三轮 reviewer 的 4 个 Important 已继续按 RED/GREEN 修复：同步 retry 样本收口不得把下一 attempt 的真实派发拖过总 deadline；误标 SSE 的 `data:` 字段名与 JSON 跨 chunk 时不能误算普通文本 progress；EOF 纯 CR 终态事件必须参与 usage/结构/reasoning 判定；`stream_action=disconnect` 已写响应后遇到受保护超大 SSE 必须取消上游、断开下游并记录专用 final action。2026-07-15 使用 Codex bundled Node 串行运行四套 E2E、六个 JS syntax、三份 PowerShell AST、`git diff --check` 和临时进程审计均通过，等待最终双 reviewer 复审。

第四轮双 reviewer 合并出的 6 个独立 Important 已继续 RED/GREEN：四种共享 retry 统一使用最终 deadline 派发闸门；旧 retry sample 不等待下一响应头并按捕获时间及时落盘；误标 SSE 使用字段内部跨 chunk 的有界待判/普通文本回退；支持流首 UTF-8 BOM；EOF 才确认的 reasoning/final-only disconnect 实际断连；policy retry 后 fetch failure 仍单独计入 failed 并保持 attempt 恒等式。对应 gateway E2E 已通过，等待完整验证与原 reviewer 最终复审。

第五轮 reviewer 的 4 个 Important 已继续 RED/GREEN：误标首个超大 SSE 候选无法绕过检查上限；独立 BOM chunk 不算 progress；普通文本 fallback 后的尾随候选不覆盖本 chunk progress；首 progress/total 完成路径按墙钟复核，不依赖延迟 timer 回调顺序。两个采集 Minor 同步收紧：未派发 timeout 明确保持 retry 字段为空，旧 policy sample 的 evidence 上界不跨入下一 attempt。对应 gateway E2E 与三套生命周期 E2E 已通过，等待最终完整验证与复审。

第六轮 reviewer 合并出的 3 个独立 Important 已继续关闭：超大候选测试改为首个且唯一事件就是 `response.completed`；检查上限在 progress/first-progress timeout 之前 fail-closed；每个流式 chunk 在 progress 分类前无条件复核 first-progress 墙钟。BOM 测试改为按 UTF-8 字节跨 chunk，旧 policy sample 进一步断言 evidence 上界早于当前请求的内部重试完成日志。Windows 跨进程 `Date.now()` 曾出现 4ms 回拨，测试只对该跨进程比较保留 50ms 容差，样本唯一性、800ms 挂起期间及时可见、duration 上界和日志 evidence 顺序仍为硬断言。修正后 gateway E2E 单轮通过并连续 3 轮稳定性复跑通过。

第七轮双 reviewer 合并出的 3 个独立 Important 和 3 个独立 Minor 已核实并按 RED/GREEN 关闭：所有 request/header 同步准备移到 retry 最终 deadline 闸门前，fetch 启动后才记预算、total/active；非流式 JSON/脱敏、流式 SSE/结构、EOF、reader 异常和客户端写入前补绝对墙钟复核；非流式 observe-only 在实际透传后再冻结样本；Capacity/429 trigger 与最终 outcome 分开计数；PowerShell canonical JSON 先保留标量再递归对象；lifecycle 反例改为前序 chunk 在 deadline 前、后续 chunk 首次跨线。RED 分别复现 200 误透传、第二次 fetch 在 deadline 后仍派发、采集字段空值、trigger 漏计和标量数组对象化；GREEN 后 gateway E2E 连续 3 轮通过，安装恢复、Windows launch、Unix launch 三套 E2E 全部通过。

- [x] **Step 2：执行完整本地验证**

```powershell
node .\scripts\test-gateway-e2e.mjs
node .\scripts\test-install-restore.mjs
node .\scripts\test-launch-ui.mjs
node .\scripts\test-launch-ui-unix.mjs
node --check .\gateway.mjs
node --check .\scripts\admin-lib.mjs
git diff --check
```

执行 PowerShell AST、临时 gateway 进程审计和 Git snapshot governance。不得以部分测试替代完整结果。

- [ ] **Step 3：双 reviewer 同题审查**

两个 reviewer 都回答同一问题：

```text
可叠加策略是否在所有流式/非流式、重试预算、已写响应、配置迁移和详细采集边界下安全，且没有破坏 516、final-only、压缩豁免、续写与真实路由语义？
```

Reviewer A 重点检查代理/时序/HTTP 状态机；Reviewer B 重点检查配置/UI/迁移/统计/测试。所有 Critical/Important 必须修复并由原 reviewer 复审。

- [ ] **Step 4：重跑完整验证并提交文档**

```powershell
git add README.md build.md err.md docs/plans/sessions/crg-layered-gateway-policies.md .ai-growth-os/runtime-workflows/crg-layered-gateway-policies.yml
git commit -m "docs: document layered gateway policies"
```

- [ ] **Step 5：先收口依赖 PR #25**

确认 #25 仍指向已审查 commit，检查合并状态后合并。同步 `main` 后确认本分支相对 `main` 只包含 issue #26 改动。

- [ ] **Step 6：推送、创建并合并新 PR**

PR 必须 `Closes #26`，列出双 reviewer、完整本地验证和“未应用真实 gateway”。确认 PR diff、base/head 和 issue 关联后再合并；合并后读取 merge commit 并确认 issue 已关闭。

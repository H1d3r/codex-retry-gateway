# err.md

## 当前默认值说明

- 早期排错记录里出现的 `guard_retry_attempts=3` 是历史默认；当前项目默认以 `gateway.mjs`、`config.example.json`、`README.md` 和 `build.md` 为准，默认值已经调整为 `5`。
- `stream_action=continuation_recovery` 只让 `reasoning_tokens` 主规则命中的 Responses 流式请求进入安全续写；`final_answer_only_high_xhigh` 实验规则即使选择该动作，也只共用 `guard_retry_attempts` 做普通内部重试/最终拦截。

## 2026-07-06 Responses 流式安全续写不能透出截断轮输出

### 现象

- `stream_action=continuation_recovery` 命中 516 / 1034 / 518*n-2 后，真实用户反馈续写结果会出现输出不完整或语义断裂。
- 本机 analytics 元数据显示，大量 `continuation_recovery` 样本在命中轮已经观察到 `has_output_text=true` / `has_final_answer=true`，说明命中轮可能已经吐出 tentative final / message / tool / reasoning 片段。
- 经过后续安全复盘，命中轮的 visible output、tool call、message、reasoning item 和 `encrypted_content` 都不能当成确定输出；不能为了“补全前半段”把命中轮片段拼接给客户端。

### 根因

- 续写恢复的目标不是保留命中轮片段，而是在命中当前规则后丢弃不可信轮，基于原始 input 发起安全续写。
- 旧讨论中“把前面非终止 SSE 片段带到最终响应”的思路会把降智/截断轮内容混入最终 envelope，导致同一个下游 SSE 混用不同 `response.id` / `model`，且可能透出 tentative tool / final / reasoning。
- 因此正确修复是：命中轮只作为触发信号；中间轮只计入观测和拦截统计，不进入客户端输出，也不进入下一轮续写上下文。
- 如果简单回退 `internal_retry`，会把“续写恢复”偷换成“重新生成”，不符合 `continuation_recovery` 的产品语义。

### 处理

- 为 Responses 流式续写增加安全语义折叠策略：
  - 命中续写前，不保留命中轮 lifecycle；reasoning item / message / final answer / function call / tool call 都视为 tentative output。
  - 截断轮所有可见/可执行输出命中后丢弃，不透给客户端，也不进入下一轮续写上下文。
  - 丢弃中间轮 `response.created` / `response.in_progress` / `response.completed` / `response.failed` / `response.incomplete` / `[DONE]`。
  - 最终干净轮返回时，保留最终轮自带 lifecycle、输出、`response.completed` 与 `[DONE]`。
  - 不混用命中轮与最终轮的 `response.id` / `model`，避免一个下游 SSE envelope 身份不一致。
- 续写请求删除 `previous_response_id`，只显式 replay 原始 input 并追加 `phase=commentary` 标记；默认不自动请求 `reasoning.encrypted_content`；原始 input 中的 reasoning item / `encrypted_content` 会在续写 replay 前过滤；请求摘要对畸形 JSON 也按敏感文本 fail-closed 脱敏；命中轮 encrypted reasoning item 不 replay 到下一轮，也不再作为继续安全续写的必要门槛。
- Responses 流式续写安全模式继续复用 `stripEncryptedContentFromSseBody()`，即使原请求显式 include `reasoning.encrypted_content` 且本轮未命中，最终透传响应也不向客户端暴露 `encrypted_content`；畸形 SSE / JSON fallback 中疑似敏感片段会被 redacted。
- 不改变拦截规则、不改变 `guard_retry_attempts` 语义、不把续写恢复降级成普通内部重试。

### 验证

- 红测：
  - `node .\scripts\test-gateway-e2e.mjs`
  - 先失败在 `续写恢复第二轮请求应删除 previous_response_id，续写状态由显式 input replay 承载`
  - 语义 fold 断言覆盖：截断轮 `fold-part-a` 不应透出，截断轮 `function_call` / `call_test_1` / tool arguments 不应透出，最终干净轮 `fold-part-b` 与 `[DONE]` 必须保留。
  - 多 agent 审查补充红测：`516 -> 1034 -> 128` 中，516 / 1034 连续命中都继续安全续写；第 2 / 3 次续写请求都只能基于原始 input 追加 1 个 commentary marker；最终 SSE 的 `response.created` / `response.in_progress` / `response.completed` 必须全部来自最终干净轮；也不应透出 mixed `response.output_snapshot` 夹带的 `snapshot-tentative-final`。另补 `516 -> 1034 -> 18` 耗尽用例，确认次数耗尽后仍命中返回 `502` 且不透出中间轮 SSE。
- 修复后：
  - `node --check .\gateway.mjs`
  - `node --check .\scripts\test-gateway-e2e.mjs`
  - `node .\scripts\test-gateway-e2e.mjs`

## 2026-07-06 Responses 流式安全续写的 encrypted_content 脱敏边界

### 现象

- 多 agent 复审发现多个隐私边界：
  - `stream:true` 请求如果上游返回 `text/plain` / 非 JSON / 非 SSE，响应体没有 `data:` 行时会绕过 SSE JSON 脱敏，可能把 `encrypted_content` 原样透给客户端。
  - 畸形 JSON 请求体如果 `encrypted_content` 的值是对象、数组或未加引号值，原文本脱敏只替换字段名，可能把敏感值落入 `request_payload_excerpt`，并随 JSON / CSV 导出。
  - 畸形 JSON 请求体如果把 key 写成 `\u0065ncrypted_content` 这类 escaped-letter 形式，旧归一化只能识别 `\u005f`，会把 key 和敏感值一起落盘。
  - SSE block 有合法 `data:` 行时，旧逻辑只清理 data payload，`event:` / `id:` / comment 这类 non-data 行如果带 `encrypted_content=...` 会原样透传。
  - 历史 day file、同步导出、后台导出下载都应在出口再做一次脱敏，不能假设早期样本一定已经干净。

### 根因

- `stripEncryptedContentFromSseBody()` 对无 `data:` 的普通文本块直接返回原文；有 `data:` 行时也只清理 data payload，没有处理 non-data metadata 行。
- `redactEncryptedContentText()` 之前主要覆盖 `encrypted_content: "字符串"`，对畸形对象 / 数组值无法确定边界，也没有处理 `encrypted_content=...` 这类 KV 形式。
- `normalizeEscapedEncryptedContentKey()` 只把 `\u005f` 归一化为 `_`，不能识别 `\u0065ncrypted_content` 这类 escaped-letter key。
- `clonePlainSample()` 没有对 `request_payload_excerpt` 做出口二次脱敏，历史脏样本可能继续进入 JSON / CSV / 后台导出 / 日文件。

### 处理

- 文本脱敏改为扫描 `encrypted_content:` 后的值边界：字符串、对象、数组、未加引号值都会整体替换为 `"redacted_sensitive_content":true`。
- escaped ASCII unicode 归一化从只处理 `\u005f` 扩展为处理 `\u00xx` 级别的 ASCII key 片段；无敏感命中时保留原文，避免无关请求摘要被改写。
- `encrypted_content=...` 这类 KV 形式会把 key 和 value 一起替换为 `redacted_sensitive_content=true`。
- `stripEncryptedContentFromSseBody()` 遇到无 `data:` 但疑似包含 `encrypted_content` 的文本块时，也走同一文本脱敏路径；有 `data:` 行时，non-data 行也逐行脱敏。
- `clonePlainSample()` 对 `request_payload_excerpt` 做出口二次脱敏，覆盖内存样本、日文件 flush、同步 JSON / CSV 导出和后台导出下载。
- E2E 补充：
  - 畸形请求体中对象 / 数组 / 未加引号值 / escaped-letter key 不落 `request_payload_excerpt`，也不进入 JSON / CSV / 后台导出 / 日文件。
  - 同步 JSON / CSV、后台导出下载和日文件都同时断言“样本定位 key 仍存在”与“`encrypted_content` 字段名、escaped key、敏感值均不存在”，避免用空导出或过滤样本伪通过。
  - 后台导出测试使用覆盖当前日期的动态大范围日期段，仍触发后台任务，但不再固定在历史月份导致空测。
  - `stream:true` + `text/plain` fallback 不向客户端暴露 `encrypted_content` 或敏感值。
  - SSE metadata non-data 行不向客户端暴露 `encrypted_content` 或敏感值。

### 验证

- 红测先失败在：`对象/数组值畸形 JSON 请求摘要不应落盘 encrypted_content 字段或值`。
- 多 agent 复审补充红测后，先失败在：`escaped-letter key 畸形 JSON 请求摘要不应落盘 encrypted_content 字段或值`。
- 修复 escaped-letter 后继续失败在：`stream:true SSE metadata 行不应向客户端暴露 encrypted_content`，证明 KV value 仍会泄漏。
- reviewer 复审后又发现后台导出下载原测试固定 `2026-01-01..2026-03-15`，当前日期样本不会进入该范围，属于空测；已改成覆盖当前日期的动态 40 天范围，并断言导出样本数组包含畸形样本 key。
- 修复后通过：
  - `node --check .\gateway.mjs`
  - `node --check .\scripts\test-gateway-e2e.mjs`
  - `node .\scripts\test-gateway-e2e.mjs`
## 2026-07-02 reasoning 分桶表不应把 count=1 的 token 显示成“高频 token”

### 现象

- reasoning 行为统计里的三张分桶表：
  - 按模型家族
  - 按思考等级
  - 模型家族 × 思考等级
- 右侧原“高频 token”列会显示类似：
  - `0 x4, 516 x2, 8 x1`
- 当分桶样本较多且 reasoning token 分散时，`x1` 这类低频值被展示成“高频 token”，用户会误以为该列是完整、可靠的高频分布。

### 根因

- 后端 `summarizeGroupedSamples()` 固定取分桶内 `topReasoningTokensForSamples(samples, 3)`。
- 该逻辑只是 Top 3 摘要，不等于真正高频。
- 前端 `formatReasoningTokens()` 也没有过滤 `count=1`，导致低频 token 被画进“高频 token”列。

### 处理

- 分桶表改为展示“重复 token”：
  - 后端只返回分桶内出现次数大于 `1` 的 reasoning token。
  - 前端再次过滤 `count<=1`，兼容旧数据或旧缓存。
  - 没有重复 token 时显示 `无重复 token`。
- 全局“高频 token 排行”不变，因为它是独立的全局排行榜。

### 验证

- 红测：
  - `node .\scripts\test-gateway-e2e.mjs`
  - 先失败在 `reasoning 模型家族聚合表不应把 count=1 的低频 token 显示为高频 token`
- 修复后：
  - `node .\scripts\test-gateway-e2e.mjs`

## 2026-07-02 Issue #11：上游 Selected model is at capacity 应在网关内重试

### 现象

- 上游返回：
  - `Selected model is at capacity. Please try a different model.`
- 旧行为会把该错误直接透传给 Codex。
- 用户期望这类 capacity 响应由 gateway 内部吞掉并重试，减少会话被上游临时容量波动打断。
- 同时该能力必须能开关，避免策略效果不好时无法回退。

### 根因

- 旧的 `guard_retry_attempts` 只服务于“命中本地拦截规则”的响应。
- 上游真实 HTTP 错误此前按保守策略全部透传，避免误吞普通 `429` / `502`。
- Issue #11 的 capacity 文案是更窄的上游容量错误特征，可以单独处理，但不能泛化成“所有 429 都重试”。

### 处理

- 新增配置：
  - `retry_upstream_capacity_errors`
  - 默认 `true`
  - 管理页可开关，保存后热生效
- 开启后，仅当上游错误响应包含：
  - `Selected model is at capacity. Please try a different model.`
  - 且 HTTP 状态为错误状态时，才触发内部重试。
- capacity 内部重试与本地规则内部重试共用 `guard_retry_attempts`：
  - `0` 表示不重试，直接透传或按现有规则返回
  - 大于 `0` 时吞掉本次 capacity 响应并重新请求上游
- 普通 `429` / `502` 不匹配该文案时仍原样透传。
- 这类被吞掉的 capacity 响应会落 reasoning analytics 样本：
  - `final_action=upstream_capacity_internal_retry`
  - `blocked_by_gateway=true`
  - `matched_current_rule=false`

### 验证

- 红测：
  - `node .\scripts\test-gateway-e2e.mjs`
  - 先失败在 `retry_upstream_capacity_errors 默认应为 true`
- 修复后：
  - `node --check .\gateway.mjs`
  - `node --check .\scripts\admin-lib.mjs`
  - `node --check .\scripts\test-gateway-e2e.mjs`
  - `node --check .\scripts\test-install-restore.mjs`
  - `node .\scripts\test-gateway-e2e.mjs`
  - `node .\scripts\test-install-restore.mjs`

## 2026-07-02 final answer only 模式不能拦截 Codex 上下文压缩请求

### 现象

- `final_answer_only_high_xhigh` 模式下，Codex 压缩上下文时可能收到 `reasoning_tokens=0` 或缺失 usage 导致 `reasoning_tokens=null`。
- 压缩响应结构可能接近 `final answer only + commentary not observed`。
- 如果按普通 high/xhigh final answer only 响应拦截，会连续返回本地拦截状态，导致上下文压缩失败。

### 根因

- 旧规则只区分 `reasoning.effort` 和响应结构，没有区分“普通回答请求”和“Codex 上下文维护请求”。
- 本机真实 analytics 样本显示 Codex 压缩链路带有请求头：
  - `x-codex-beta-features: remote_compaction_v2`
- 该请求头足以作为请求侧特征；不能把 `reasoning_tokens=0/null` 全局放行，否则会削弱 high/xhigh final answer only 的正常拦截价值。

### 处理

- 新增请求类型识别：
  - `remote_compaction_v2` / `remote_compaction` / `context_compaction` -> `request_kind=context_compaction`
- `context_compaction` 样本不参与当前拦截规则命中：
  - 不计入 `matched_current_rule`
  - 不计入 `blocked_by_gateway`
  - 不触发 `guard_retry_attempts` 内部重试
- 样本仍完整落盘和导出：
  - `request_kind`
  - `intercept_exempt_reason=context_compaction`
  - `reasoning_tokens=0/null`
  - `final_answer_only`

### 验证

- 红测：
  - `node .\scripts\test-gateway-e2e.mjs`
  - 先失败在 `remote_compaction_v2 reasoning_tokens=0 不应被 final only 模式拦截: 502`
- 修复后：
  - `node --check .\gateway.mjs`
  - `node --check .\scripts\test-gateway-e2e.mjs`
  - `node .\scripts\test-gateway-e2e.mjs`

### 后续修正

- `x-codex-beta-features: remote_compaction_v2` 只是 Codex Desktop 的 beta feature 标记，不足以证明当前请求正在做上下文压缩。
- 真实样本显示普通 `request_kind=turn` 也会带 `remote_compaction_v2`，如果把该头直接识别成 `context_compaction`，会导致普通回答里的 `reasoning_tokens=516` 被错误豁免，既不命中规则，也不会触发 `guard_retry_attempts` 内部重试。
- 新口径：
  - 只有显式 `context_compaction` 信号才标记 `request_kind=context_compaction`
  - 只有 `context_compaction + reasoning_tokens=0` 才写 `intercept_exempt_reason=context_compaction`
  - `null`、`18`、`516/1034/1552` 等其它值不走压缩豁免，仍按当前拦截规则处理

## 2026-07-02 final answer only 实验规则普通 0 误伤风险过高

### 现象

- 用户反馈 `final_answer_only_high_xhigh` 可能出现“要么大量拦截，要么几乎不拦截”的极端表现。
- 本机样本显示普通 high/xhigh 请求里也会出现 `final_answer_only=true + reasoning_tokens=0`。
- 当前没有足够公开证据证明普通 `reasoning_tokens=0` 一定等价于降智；把 0 纳入实验硬拦截会明显提高误伤风险。

### 根因

- 旧实验规则只要求：
  - `reasoning.effort=high/xhigh`
  - `final_answer_only=true`
  - 未观察到 commentary / tool call / reasoning item
- 该规则没有区分 `reasoning_tokens=0` 与 `reasoning_tokens=null/非 0`。
- `reasoning_tokens=0` 在压缩和普通 turn 中都可能出现，单独作为硬拦截依据证据不足。

### 处理

- `final_answer_only_high_xhigh` 规则排除普通 `reasoning_tokens=0`：
  - 普通 `0 + final_answer_only + high/xhigh` 只观察落盘，不触发该实验规则。
  - `null/缺失 + final_answer_only + high/xhigh` 仍可命中。
  - 非 0 `reasoning_tokens + final_answer_only + high/xhigh` 仍可命中。
- 既有 `context_compaction + reasoning_tokens=0` 压缩豁免保持不变。
- `reasoning_tokens` 主规则不变，516/1034/1552 仍按默认主规则处理。

### 验证

- 红测：
  - `node .\scripts\test-gateway-e2e.mjs`
  - 先失败在 `普通 high final answer only reasoning_tokens=0 应放行观察: 502`
- 修复后：
  - `node --check .\gateway.mjs`
  - `node --check .\scripts\test-gateway-e2e.mjs`
  - `node .\scripts\test-gateway-e2e.mjs`

## 2026-07-01 新增 final answer only 规则样本后，模型家族精确统计需要同步

### 现象

- 为 `final_answer_only_high_xhigh` 增加高思考拦截用例后，`node .\scripts\test-gateway-e2e.mjs` 失败：
  - `gpt-5.5 家族 total_checked 统计不正确`
- 失败发生在 `model_insights.family_breakdown` 精确计数断言。

### 根因

- 新增的 high/xhigh final answer only 请求不仅验证拦截规则，也会进入既有模型一致性统计。
- 这些请求的上游声明模型与请求模型一致，因此会同时增加 `total_checked` 与 `matched`。
- 旧断言使用精确数值，不会自动吸收新增样本。

### 处理

- 保留精确断言，不改成宽松 `>=`。
- 将 `gpt-5.5` 家族统计同步到新增样本后的真实口径：
  - `total_checked = 13`
  - `matched = 12`
  - `match_ratio = 12 / 13`
- 断言失败信息补充实际值，避免后续靠猜测调整。

### 验证

- `node .\scripts\test-gateway-e2e.mjs`

## 2026-07-01 reasoning 特征分析新增 helper 时不要复用既有通用函数名

### 现象

- 为 `/api/analytics/reasoning/analyze` 增加分析 Profile 解析时，新增了一个本地 helper：
  - `normalizeStringList`
- `node --check .\gateway.mjs` 直接失败：
  - `SyntaxError: Identifier 'normalizeStringList' has already been declared`

### 根因

- `gateway.mjs` 早已有全局 `normalizeStringList(values, fallback)`，用于配置归一化。
- 新增分析模块又声明了同名函数，ESM 顶层作用域不允许重复声明。

### 处理

- 将分析模块私有 helper 改名为：
  - `normalizeAnalysisStringList`
- 所有分析 Profile 和过滤条件解析统一使用新名字，避免影响旧配置归一化逻辑。

### 验证

- `node --check .\gateway.mjs`
- `node --check .\scripts\test-gateway-e2e.mjs`
- `node .\scripts\test-gateway-e2e.mjs`

## 2026-07-01 历史导入分析指定 source_paths 时不能再混入默认真实大库

### 现象

- 新增历史导入分析后，E2E 使用临时 SQLite 小库触发 `/api/analytics/imports/run`。
- 任务进度停在 `processed_sources=2/4`，已经完成测试用 CC Switch 和 Codex logs 小库，但又继续扫描默认 `%USERPROFILE%\.codex\logs_2.sqlite` 等真实大库。
- 这会让测试变慢，也会在用户只想分段导入时误扫 1GB / 2GB 级历史库。

### 根因

- `buildHistoricalImportSources()` 对每个数据源都使用“请求路径或默认路径”的写法。
- 只要某个可选 alt 路径没传，就会自动补默认真实路径。
- 这与“传入 `source_paths` 就只分析指定源”的分段导入语义冲突。

### 处理

- 增加 `hasRequestedSources = Object.keys(source_paths).length > 0`。
- 当请求体传入任意 `source_paths` 时，只收集显式指定的数据源，不再混入默认真实大库。
- 不传 `source_paths` 时，才自动发现本机默认 CC Switch、Codex logs 和 Codex sessions。

### 验证

- `node --check .\gateway.mjs`
- `node --check .\scripts\test-gateway-e2e.mjs`
- `node .\scripts\test-gateway-e2e.mjs`

## 2026-07-01 reasoning 大范围导出不应 31 天硬拒绝，应后台分段导出

### 现象

- 第一版大范围保护把 `31` 天以上 JSON / CSV 导出做成 HTTP `413` 拒绝。
- 用户明确要求大范围导出可以分段慢慢导出，要有进度条和提醒，但不能影响正常代理工作。
- 如果继续用 `413`，后续 60 天、90 天复盘都要人工拆日期，容易漏数据，也不符合“大盘离线分析”的使用方式。

### 根因

- 之前只实现了“防止 UI 卡死”的保护，没有补后台任务通道。
- 同步导出适合短时间段，但长时间段应该从交互请求里拆出去。

### 处理

- 保留 `31` 天以内同步 JSON / CSV 导出。
- `32` 天及以上改为返回 HTTP `202`，并创建后台导出任务：
  - 返回 `export_job.job_id`
  - 返回 `progress.total_days / processed_days / percent`
  - 后台按本地日期逐日读取 analytics 日文件和内存缓冲
  - 每处理一天后让出事件循环，避免长循环占住代理主链路
  - 完成后写入 `<state_root>/analytics/exports/<job_id>/reasoning-export.json|csv`
  - 新增任务状态接口和下载接口
- 管理页导出按钮改为先创建任务，再轮询进度；页面显示“可以继续正常使用 gateway”的提醒，完成后展示下载链接。

### 验证

- `node --check .\gateway.mjs`
- `git diff --check`
- `node .\scripts\test-gateway-e2e.mjs`

### 边界

- 后台任务状态当前保存在 gateway 进程内存中，进程重启后任务状态不会恢复。
- 当前不引入数据库，不打 zip；后续再补每日 rollup、明细索引和压缩包导出。
- 没有重启当前本机 `127.0.0.1:4610` 工作路由。

## 2026-07-01 reasoning analytics 缺少机器可判定激活信号，且大范围查询可能无边界深解析

### 现象

- 补完 reasoning analytics 后，文档要求用硬信号判断新进程是否真正激活。
- 但 E2E 新增断言后首先失败：
  - `status reasoning_behavior 缺少 schema_version=2`
- 这说明状态接口虽然返回了 `reasoning_behavior` 聚合数据，但缺少机器可判定字段。
- 同时，`date_from/date_to` 时间段接口和导出接口会直接读取命中范围内的日文件；如果时间段很大，后续有被大量日文件拖慢的风险。

### 根因

- `buildReasoningBehaviorSnapshotFromSamples()` 只返回业务统计，没有返回 analytics schema 和 ready 状态。
- `buildReasoningBehaviorRuntimeSnapshot()` 也没有追加运行期元信息，例如：
  - `analytics_started_at`
  - `analytics_state_root`
  - 最近 flush 状态
- 时间段查询和导出接口没有先计算日期跨度，也没有大范围降级或拒绝策略。

### 处理

- reasoning snapshot 统一补：
  - `schema_version = 2`
  - `analytics_ready = true`
- runtime metadata 补：
  - `analytics_started_at`
  - `analytics_state_root`
  - `analytics_last_flush_at`
  - `analytics_last_flush_error`
- 状态接口、独立观测接口、JSON 导出都带上这些硬信号。
- 大范围观测查询增加软降级：
  - 超过 `7` 天返回 `degraded=true`
  - `degrade_reason=date_range_too_large`
  - 不返回明细样本
- 第一版大范围导出曾增加明确拒绝：
  - 超过 `31` 天返回 HTTP `413`
  - 错误码 `reasoning_export_range_too_large`
  - 提示缩小范围或后续使用分片/压缩包导出
- 后续已升级为后台分段导出任务；详见上一条 2026-07-01 记录。

### 验证

- 红测：
  - `node .\scripts\test-gateway-e2e.mjs`
  - 先失败在 `status reasoning_behavior 缺少 schema_version=2`
- 修复后：
  - `node --check .\gateway.mjs`
  - `git diff --check`
  - `node .\scripts\test-gateway-e2e.mjs`

### 边界

- 这次先实现硬信号和大盘查询降级边界。
- 没有引入数据库。
- 后台分段导出已在后续记录中补齐，但压缩包导出仍未实现。
- 没有重启当前本机 `127.0.0.1:4610` 工作路由。

## 2026-06-30 reasoning 行为统计 runtime 状态未初始化会让旁路请求直接 502

### 现象

- `node .\scripts\test-gateway-e2e.mjs` 最早失败在：
  - `/v1/models 透传状态异常: 502`
- `/v1/models` 不在 reasoning 检查 endpoints 内，理论上应该只是旁路透传。

### 根因

- 普通代理请求进入后会立即调用：
  - `nextGatewayRequestId(runtime.reasoningBehavior)`
- 但 `runtime` 初始化时没有挂 `reasoningBehavior: createReasoningBehaviorState()`
- 旁路请求还没发到上游，就因为本地状态为空抛错，被顶层 catch 映射成 502。

### 处理

- 在运行时初始化对象中补齐：
  - `reasoningBehavior: createReasoningBehaviorState()`
- 这样所有普通代理请求进入时都能分配 `gateway_request_id`，旁路、检查、失败、重试都共享同一套采集状态。

### 验证

- `node --check .\gateway.mjs`
- `node .\scripts\test-gateway-e2e.mjs`

## 2026-06-30 inspected 主链 handler 如果不落样本，reasoning 大盘会只剩旁路和失败样本

### 现象

- UI 大盘补齐后，E2E 继续失败：
  - `reasoning 行为样本总数不正确`
- 状态接口里 `reasoning_behavior.summary.total_samples` 明显偏低，只看到旁路、拒绝或失败样本。

### 根因

- `proxyRequest()` 已经为每次 attempt 创建了 `reasoningSample` 和 `structureAccumulator`
- 但 `handleNonStreaming()` / `handleStreaming()` 没有接收和使用这两个对象
- handler 内部返回 `passed`、`observe_only`、`blocked`、`internal_retry` 时没有调用 `finalizeReasoningBehaviorSample()` 和 `recordReasoningBehaviorSample()`
- 流式分支也没有记录首 chunk、首内容、最终 chunk、usage 与结构信号。

### 处理

- `handleNonStreaming()`：
  - 补 usage、响应结构信号
  - 按 `passed` / `observe_only` / `blocked` / `internal_retry` 落样本
- `handleStreaming()`：
  - 补 `first_stream_chunk_at`、`first_content_at`、`final_chunk_at`
  - 累计 SSE payload 的 usage、模型信号和结构信号
  - 按 `passed` / `observe_only` / `blocked` / `internal_retry` / `disconnect` / `upstream_stream_terminated` 落样本
- `upstream_fetch_failed` 样本统一记录 `client_http_status = 502`
- CSV 导出补充流式时序、结构信号、内部重试与 stream termination 字段。

### 验证

- `node --check .\gateway.mjs`
- `node .\scripts\test-gateway-e2e.mjs`

## 2026-06-29 reasoning 统计如果只记“有正常上游响应的请求”，后面很多关键字段会永远缺失

### 现象

- 用户新要求变成：
  - 每一次请求都尽量详细
  - 连当前被拦截的请求也要详细落盘
  - 后续要区分 `gpt-5.4` / `gpt-5.5` 和 `reasoning.effort`
- 旧实现虽然已经有 reasoning 样本，但主要还是围绕“已检查响应”展开：
  - 正常透传和命中规则请求比较完整
  - 但像旁路透传、上游 `fetch failed`、请求体超限这类请求，要么没进样本，要么字段很薄

### 根因

- reasoning 样本之前是围绕 `upstreamResponse` 和检查链路补的
- 请求在这些更早的阶段失败时：
  - 还没进入 `handleNonStreaming()` / `handleStreaming()`
  - 甚至还没完成上游连接
- 结果会导致“统计总数看起来不少，但关键失败请求没有事实样本”

### 处理

- 把 reasoning 样本入口前移到 `proxyRequest()`：
  - 一开始就分配 `gateway_request_id`
  - 一开始就创建请求摘要 accumulator
- 落盘范围扩成：
  - 正常透传
  - observe_only
  - blocked
  - internal_retry
  - bypassed
  - upstream_fetch_failed
  - request_rejected
- 每条样本尽量保留：
  - 请求 headers 脱敏副本
  - 请求体大小 / sha256 / 摘要
  - 请求结构摘要
  - 上游状态 / 客户端状态
  - 失败摘要 / 响应摘要
  - `gpt-5.4` / `gpt-5.5` family
  - `reasoning.effort`
- 聚合新增：
  - `by_model_family`
  - `by_reasoning_effort`
  - `by_model_family_and_effort`

### 验证

- `node .\scripts\test-gateway-e2e.mjs`
  - reasoning analytics 状态接口新增 family / effort / family+effort 分桶断言
  - reasoning JSON 导出新增请求摘要、失败摘要、客户端状态断言
  - reasoning 日文件新增 `schema_version = 2` 和失败样本断言
- `node .\scripts\test-install-restore.mjs`
  - 安装/恢复回归继续通过

## 2026-06-29 reasoning 统计新增模型/思考等级样本后，模型一致性旧断言需要同步调整

### 现象

- 为了让 reasoning analytics 真正产出 `gpt-5.4` / `gpt-5.5` 与 `reasoning.effort` 分桶
- E2E 新增了几条带不同模型和 effort 的真实请求
- 结果 `model_insights.family_breakdown` 的旧精确断言直接失败
  - 例如 `gpt-5.4 total_checked` 从旧值涨到了新值

### 根因

- 这些新增请求不只是 reasoning analytics 的样本
- 同时也会进入原有 `finalizeModelInsights()` 统计
- 所以 `family_breakdown` 的精确计数必须跟着真实新增样本一起调整

### 处理

- 保留精确断言，不改成模糊的 `>=`
- 先打印实际 `family_breakdown` 真值确认影响面
- 再把 E2E 中这组旧计数同步更新到新口径

### 验证

- `node .\scripts\test-gateway-e2e.mjs` 通过

## 2026-06-29 reasoning 行为统计导出不能只读日文件，必须合并内存缓冲样本

### 现象

- 新增 reasoning 行为统计后：
  - 状态接口和管理页已经能看到最新样本
  - 但 `GET /__codex_retry_gateway/api/analytics/reasoning/export?format=json` 导出的 `samples` 为空或显著偏少

### 根因

- 运行中样本先进入内存 recent window 和 daily buffer
- 日文件写入是节流 flush，不保证每次请求后立刻落盘
- 导出接口如果只读取 `analytics/reasoning-behavior-YYYY-MM-DD.json`，会漏掉尚未 flush 的最新样本

### 处理

- 导出读取逻辑改成：
  - 先读日期范围内的日文件
  - 再合并当前内存里的 `reasoning_behavior_daily_buffers`
  - 最后统一排序并重新计算导出统计

### 验证

- `node .\scripts\test-gateway-e2e.mjs`
  - 新增 reasoning JSON 导出包含样本断言
  - 新增 reasoning CSV 导出包含表头断言

## 2026-06-29 主动探针测试夹具必须与 stateRoot / auth 查找规则对齐

### 现象

- 新增 reasoning 行为统计后，主动探针相关 E2E 超时
- 状态接口显示：
  - `active_probe.total_runs = 1`
  - 但 `recent_samples` 大量是 `401`
  - `error_excerpt = missing_authorization | authorization header required`

### 根因

- 网关读取鉴权时会按两条路径查找：
  - `path.dirname(codex_config_path)/auth.json`
  - `runtime.paths.stateRoot/auth.json`
- 不同测试场景的 `config.json` 布局不同：
  - 有的是 `<root>/config/config.json`
  - 有的是 `<root>/probe-runtime/config.json`
- 测试夹具若把 `state.json` / `auth.json` 写到错误层级，主动探针就会稳定落到 `401 indeterminate`

### 处理

- 保持 `buildRuntimePaths()` 规则不变：
  - 目录名为 `config` 时，`stateRoot = 上一级`
  - 其他情况，`stateRoot = config.json 所在目录`
- E2E 测试夹具按对应场景写入 `state.json` / `auth.json`
- 对关键 probe 场景额外补一份 `auth.json` 到 `codex_config_path` 同目录，避免目录布局差异再次误伤

### 验证

- `node .\scripts\test-gateway-e2e.mjs`
  - 主动探针长上下文 / warning / 缺鉴权场景全部恢复通过

## 2026-06-29 Issue #6：旧配置缺字段导致 PowerShell StrictMode 安装失败

### 现象

- 用户更新后执行：
  - `powershell -ExecutionPolicy Bypass -File .\scripts\launch-ui.ps1`
- 报错：
  - `The property 'intercept_streaming' cannot be found on this object`
  - 位置指向 `scripts\install-for-current-provider.ps1`

### 根因

- 旧版 `config.json` 没有 `intercept_streaming` / `intercept_non_streaming` / `guard_retry_attempts` 等新增字段
- PowerShell 脚本启用了 `Set-StrictMode -Version Latest`
- 在 StrictMode 下直接访问 `$existingGatewayConfig.intercept_streaming`，缺字段会抛异常，不能像普通 PowerShell 那样默认为 `$null`

### 处理

- `install-for-current-provider.ps1` 新增本地 helper：
  - `Get-OptionalPropertyValue`
- 所有可选旧配置字段统一通过 `PSObject.Properties[...]` 安全读取
- 缺失字段回落默认值：
  - `intercept_streaming = true`
  - `intercept_non_streaming = true`
  - `guard_retry_attempts = 3`
  - 其他字段沿用既有默认
- `scripts/test-install-restore.mjs` 增加旧配置缺字段后再次执行安装脚本的回归覆盖

### 跨平台补充

- 本轮专门重跑 Windows 和 Unix 入口测试
- 发现当前 worktree 缺 `.gitattributes`，导致 `.sh` 入口再次变成 CRLF，Bash 报：
  - `set: pipefail\r: invalid option name`
- 新增 `.gitattributes`：
  - `*.sh text eol=lf`
- 将现有 `.sh` 入口统一转为 LF

### 验证

- `node .\scripts\test-install-restore.mjs` 通过
- `node .\scripts\test-launch-ui.mjs` 通过
- `node .\scripts\test-launch-ui-unix.mjs` 通过

## 2026-06-29 命中拦截规则后不能继续把失败状态码暴露给 Codex

### 现象

- 规则拦截此前会向 Codex 返回本地 `502`
- Codex 遇到失败状态后会自动 `Reconnecting...`
- 连续重连达到上限后，会话可能断开
- 实测 `409` 和 `422` 也会触发 Codex 自动重连，不能作为最终拦截收口状态码

### 根因

- 网关把“本地规则拦截”伪装成 HTTP 失败状态返回给 Codex
- Codex 无法区分这是本地规则命中，还是上游真实故障
- 早期为了快速上线依赖 Codex 自身重连，导致命中规则时有断会话风险

### 处理

- 新增 `guard_retry_attempts`
  - 默认 `3`
  - 必须是大于等于 `0` 的整数
  - `0` 表示不做网关内部规则重试
  - 无上限，管理页保存后立即生效
- 仅当响应命中当前拦截规则且会被实际拦截时，网关内部重新请求上游
- 上游真实 HTTP `429` / `502` 等错误如果没有命中规则，继续原样透传给 Codex
- `fetch failed` 仍按既有上游连接失败逻辑处理，本轮不改变其语义
- 内部重试统计沿用现有 UI 口径：
  - 每次上游尝试计入代理请求总数
  - 每次被检查的响应计入被检查响应总数
  - 命中规则计入当前规则命中总数
  - 被吞掉重试或最终拦截计入实际拦截总数
- 命中日志动作：
  - `action=internal_retry remaining=N`：本次命中被网关吞掉，并继续内部重试，没有暴露给 Codex
  - `action=return_status_502`：重试次数为 `0` 或已达到上限，本次才真正向 Codex 返回拦截状态
  - `action=observe_only`：当前类型命中但配置为只观察不拦截

### 验证

- `node .\scripts\test-gateway-e2e.mjs`：
  - 覆盖非流式 `516 -> 128` 内部重试恢复为 `200`
  - 覆盖流式 strict `516 -> 128` 内部重试恢复为正常 SSE
  - 覆盖连续 `516 -> 516` 超过上限后才返回本地拦截状态
  - 覆盖上游真实 `429` 不触发规则内部重试并原样透传
- `node .\scripts\test-install-restore.mjs`：
  - 覆盖新装默认 `guard_retry_attempts = 3`
  - 覆盖旧配置迁移补默认值
  - 覆盖保存配置持久化 `guard_retry_attempts`

## 2026-06-28 长上下文主动探针从词数近似升级为 token 预算硬探针

### 现象

- 旧版 `long_context` 只按 `target_word_count` 构造重复文本
- 虽然能大致撞进 `>400K` 区间，但不能证明请求真的按目标模型口径到达了目标 token 预算

### 根因

- 上游当前不兼容官方 `responses/input_tokens` 计数接口
- 旧实现只能用词数近似，证据强度不够

### 处理

- 长上下文探针配置改为 `long_context.target_input_tokens`
- 探针先发送小样本校准请求，读取同一目标模型返回的 `usage.input_tokens`
- 再按真实返回口径估算并构造预算请求
- 样本与日志里落盘：
  - `target_input_tokens`
  - `observed_input_tokens`
  - `estimated_input_tokens`
  - `budget_source=response_usage`

### 验证

- 仓库回归：
  - `node .\scripts\test-gateway-e2e.mjs` 通过
- UI 文案回归：
  - “模型家族一致性” 改为 “模型家族一致性（被动探针）”

## 2026-06-28 主动探针图片输入误报 502 / transport_error

### 现象

- 主动探针里的 `image_input` 在真实上游上持续返回：
  - `502`
  - `transport_error` 或 `indeterminate`
- 但同一时段：
  - `long_context` 可以 `200 pass`
  - 用户手工实测 `gpt-5.4` / `gpt-5.5` 图片能力正常

### 根因

- 探针图片使用的是 `data:image/svg+xml;base64,...`
- 当前兼容链路对 `SVG data URL` 处理不稳定，真实现象会表现为上游拒绝、超时或被转写成 `502`
- 官方文档列出的常见视觉输入类型是 `png / jpg / gif / webp`，不包含 `svg`

### 处理

- 将主动探针内置图片从 `SVG data URL` 改为光栅 `PNG data URL`
- 保持探针请求结构不变，只替换图片 MIME 类型与内容
- 在 E2E 假上游里增加一条约束：
  - 若图片探针仍发送 `data:image/svg+xml`，则模拟上游异常
  - 这样可以防止后续回归把 `SVG` 又带回来

### 验证

- 仓库回归：
  - `node .\scripts\test-gateway-e2e.mjs` 通过
- 本机真实验证：
  - `gpt-5.5 image_input`：`200 pass`，证据为 `A`
  - `gpt-5.4 image_input`：`200 pass`，证据为 `A`

## 2026-06-26 独立 Codex Retry Gateway

### 设计边界

- 只解决 Codex 已可访问上游时的 `reasoning_tokens = 516` 重试问题
- 不替代 `cc-switch` 的协议路由转换
- 流式场景默认策略是：
  - 先缓存上游流
  - 一旦检测到命中 `516`
  - 统一返回 `502`

### 当前已知限制

- 如果上游只支持 Chat Completions、而 Codex 当前链路需要 Responses 协议转换，这个项目不处理该转换
- 这个项目依赖 Codex / Codex Desktop 自身的自动重试能力

### 本次已确认并修复的问题

1. `gateway.mjs` 非流式透传发头顺序错误
   - 现象：`ERR_HTTP_HEADERS_SENT`
   - 根因：`writeHead()` 在 `copyHeadersToClient()` 之前调用
   - 结果：正常 `128` 响应也会被打断

2. PowerShell 脚本在 `powershell.exe` 下的解析兼容性
   - 现象：脚本乱码并伴随解析异常
   - 根因：新脚本初版包含中文运行时字符串，且 `param(...)` 不在文件最前
   - 处理：运行时输出改成 ASCII，并把 `param(...)` 提前到文件顶部

3. `stop-gateway.ps1` 与 PowerShell 内置只读变量 `$PID` 冲突
   - 现象：安装脚本在重启 gateway 时失败
   - 处理：改用 `$gatewayPid`

4. `start-gateway.ps1` 启动 Node 时路径带空格
   - 现象：gateway 进程启动后立刻退出
   - 根因：`Start-Process` 参数未显式带引号
   - 处理：改为手工拼带引号的 `ArgumentList`

5. PowerShell 单元素数组落盘时被拆成标量
   - 现象：`reasoning_equals` 被写成 `516`，不是 `[516]`
   - 处理：在公共归一化函数里强制返回数组

6. 旧脏配置迁移后出现嵌套/拼接 endpoints
   - 现象：`endpoints` 可能变成嵌套数组，或出现一条用空格拼接的脏字符串
   - 处理：安装脚本合并 endpoints 时做递归拍平和空白拆分

7. 真实 Codex 客户端请求路径不是 `/v1/responses`
   - 现象：`codex exec` 在 gateway 关闭时真实报错地址是 `http://127.0.0.1:4610/responses`
   - 结论：默认配置必须同时覆盖：
     - `/responses`
     - `/chat/completions`
     - `/v1/responses`
     - `/v1/chat/completions`

8. UI 恢复动作最初采用“子进程拉起 restore 脚本”方案
   - 现象：浏览器拿到 `202`，但临时 `config.toml`、`state.json`、`gateway.pid` 都没有变化
   - 根因：恢复动作通过 detached 子进程接力时，链路可靠性不足，实际没有把恢复流程真正执行完
   - 处理：改为当前 gateway 进程直接复制备份、清理状态并自我退出

9. 新增内嵌 UI 管理页
   - 入口：`/__codex_retry_gateway/ui`
   - 能力：
     - 查看当前接管状态
     - 热更新 `reasoning_equals`
     - 热更新 `endpoints`
     - 热更新 `non_stream_status_code`
     - 开关 `log_match`
     - 一键恢复 Codex 原设置

10. 用户不接受 `cc-switch` 路由模式，且不希望手工改设置
   - 现象：仅有安装脚本和 UI 还不够，首次接管、再次拉起、重新打开 UI 仍需要手工串命令
   - 处理：新增 `launch-ui.ps1`
   - 结果：
     - 首次运行自动安装并打开 UI
     - 再次运行自动复用 `state.json + config.json` 并重启 gateway
     - 平时规则调整和恢复统一回到 UI 内完成

11. UI 需要动态显示实时日志、`516` 次数和占比
   - 现象：原 UI 只能改配置，看不到运行中的命中趋势
   - 处理：
     - 在 `gateway.mjs` 内增加运行期统计
     - 增加日志接口
     - UI 轮询显示“被检查响应总数 / 516 命中次数 / 516 占比 / 实时日志”
   - 统计口径：
     - 按本次 gateway 启动以来累计
     - `516` 占比 = `reasoning_tokens = 516` 的响应次数 / 被检查响应总数

12. macOS / Linux 不能直接使用现有 PowerShell 管理脚本
   - 现象：`launch-ui.ps1`、`restore-codex-config.ps1` 等入口绑定了 PowerShell 和 Windows 进程控制
   - 处理：
     - 新增跨平台 `node` 管理核心
     - 新增 `.sh` 包装入口：
       - `launch-ui.sh`
       - `restore-codex-config.sh`
       - `install-for-current-provider.sh`
       - `start-gateway.sh`
       - `stop-gateway.sh`
   - 结果：
     - Windows 继续走 `.ps1`
     - macOS / Linux 直接走 `.sh`
     - UI、状态文件、gateway 主逻辑保持同一套

13. Windows 主机上模拟 Unix shell 入口时存在路径与 Node 版本兼容问题
   - 现象：
     - Bash 入口最初找不到脚本路径
     - Bash 默认 `node` 版本过老，不支持现代语法
     - `node.exe` 需要 Windows 路径，而 shell 侧是 POSIX 路径
   - 处理：
     - 测试改成相对 POSIX 路径执行 `.sh`
     - `.sh` 优先选择 `node.exe`
     - 在 WSL / Bash 场景下把路径参数转换回 Windows 路径后再交给 `node.exe`

14. 上游流式连接中途终止时被误记为网关错误，首次瞬断也缺少最小重试
   - 现象：
     - 日志出现：
       - `TypeError: terminated`
       - `TypeError: fetch failed`
     - 其中一部分来自上游 SSE 中途断流，另一部分来自上游首次连接瞬时失败
   - 根因：
     - `handleStreaming()` 直接把 `reader.read()` 抛出的 `AbortError` / `TypeError: terminated` 冒到统一错误处理
     - `proxyRequest()` 对上游 `fetch()` 没有做一次轻量重试，首个瞬断会直接返回 `502`
   - 处理：
     - 新增预期流终止识别：
       - `AbortError`
       - `TypeError: terminated`
     - 这两类在流式处理中按“连接已结束”收口，不再记 `[error]`
     - 新增上游 `fetch failed` 的一次自动重试
     - 新增严格 `502` 流式模式：
       - 默认不再抢先透传 `200` 头和首个 chunk
       - 先缓存流，再根据 `reasoning_tokens` 决定透传或返回 `502`
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增 `/responses` 流式覆盖
       - 新增“上游半路断流不刷 error 日志”断言
       - 新增“首次 fetch failed 后第二次成功恢复”断言
       - 新增“流式 `516` 统一返回 `502`，不再先透传半截 chunk”断言
     - `scripts/test-install-restore.mjs` 继续通过

15. 管理页刷新会把代理请求总数加一
   - 现象：
     - 打开或刷新 `__codex_retry_gateway/ui` 后，页面里的“代理请求总数”会额外增加
   - 根因：
     - 浏览器自动请求 `/favicon.ico`
     - 网关未把该请求识别为管理页附属资源，落入普通代理路径并计入 `total_proxy_request_count`
   - 处理：
     - 在管理请求分支提前处理 `/favicon.ico`
     - 直接返回 `204`
     - 不再进入普通代理计数
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“管理页刷新相关请求不应增加代理请求总数”断言

16. 新增模型家族一致性检测与单请求高风险漂移检测
   - 目标：
     - 本地模型为 `gpt-5.4` / `gpt-5.5` 时，检查链路声明和行为是否符合 `1M` 家族特征
   - 处理：
     - 新增本地请求模型、上游声明模型、流式声明模型统计
     - 新增声明一致率与最近可疑样本
     - 新增 `400K` 家族异常检测
     - 新增单请求模型漂移检测
     - 新增疑似请求内重建/重试检测
   - 证据保留：
     - 每条可疑样本保留：
       - 本地期望模型
       - 上游声明模型
       - 流式声明模型
       - 首个观测模型
       - 最后观测模型
       - 模型集合
       - 指纹集合
   - 边界：
     - 声明一致不等于已证明真实运行一致
     - `400K` 家族异常只表示行为上疑似不符合 `1M` 家族
     - 单请求模型漂移与疑似请求内重建/重试都按高风险展示
     - 无法直接确认 provider 内部缓存重建
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增 `gpt-5.4` / `gpt-5.5` 一致声明断言
       - 新增 `mini` 声明不一致断言
       - 新增 `400000 context window` 异常断言
       - 新增单请求模型漂移断言
       - 新增疑似请求内重建/重试断言

17. 管理页内联脚本语法错误会导致整页状态全部不灌值
   - 现象：
     - `运行状态`、`拦截规则`、`模型家族一致性` 都显示为初始空值
     - 浏览器控制台报：
       - `SyntaxError: Invalid or unexpected token`
   - 根因：
     - 新增“日志证据”展示时，内联脚本里的 `join('\n')` 被模板 HTML 吃成了真实换行
     - 最终生成的 `<script>` 语法非法，初始化逻辑完全没有执行
   - 处理：
     - 改成 `join('\\n')`
     - 在 `scripts/test-gateway-e2e.mjs` 里新增“管理页内联脚本可被 `vm.Script` 解析”断言

18. Unix `.sh` 入口在 Bash 下因为 CRLF 行尾直接失败
   - 现象：
     - `scripts/test-launch-ui-unix.mjs` 失败
     - Bash 报错：
       - `set: pipefail\r: invalid option name`
   - 根因：
     - `.sh` 文件被写成了 `CRLF`
     - Bash 把 `\r` 当成命令内容的一部分
   - 处理：
     - 把所有 `.sh` 入口统一转成 `LF`
     - 新增仓库级 `.gitattributes`
       - `*.sh text eol=lf`

19. 最近可疑样本里的“查看日志”会在自动刷新后瞬间收起
   - 现象：
     - 点开“日志证据”里的 `查看 N 条`
     - 约 2 秒一次的页面轮询后会自动收起
   - 根因：
     - `renderSuspiciousSamples()` 每次轮询都会整体重写 `tbody.innerHTML`
     - `<details>` 的展开态属于 DOM 本地状态，节点被重建后自然丢失
   - 处理：
     - 给最近可疑样本增加签名比对
     - 样本数据没变化时不重绘
     - 样本数据有变化时保留用户已展开的 `data-sample-key` 状态并恢复
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“最近可疑样本未变化时不应重绘日志证据 DOM”断言
       - 新增“最近可疑样本刷新后已展开的日志证据不应自动收起”断言

20. 正常拦截流式 `516` 会被误报成 `single_request_rebuild_suspected`
   - 现象：
     - `/responses` 流式命中 `reasoning_tokens = 516` 被本地严格 `502` 正常拦截后
     - 管理页仍可能出现：
       - `single_request_rebuild_suspected`
   - 根因：
     - 流式 SSE 事件里的顶层 `id` 可能只是事件 id，不是响应 `response.id`
     - 监控层此前把流式 payload 顶层 `id` 也记进 `observedResponseIds`
     - 同一请求里多个事件 id 被误当成多个响应 id，触发“疑似请求内重建/重试”
   - 处理：
     - `extractPayloadResponseId()` 改为仅在非流式场景允许回退到 payload 顶层 `id`
     - 流式场景只认 `payload.response.id`
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“带事件 id 的 516 流式请求未返回 502”覆盖
       - 新增“正常拦截 516 不应计入疑似请求内重建/重试”断言
       - 新增“正常拦截 516 不应生成 single_request_rebuild_suspected 可疑样本”断言

21. 管理页实时日志时间显示与本机时间不一致，且代理请求总数与被检查响应总数差值缺少解释
   - 现象：
     - “实时日志”直接显示原始 UTC 时间串
     - `代理请求总数` 与 `被检查响应总数` 存在差值时，页面看不出是哪些请求造成的
   - 根因：
     - `renderLogs()` 直接输出 `entry.at`，没有复用 `formatTimestamp()`
     - `total_proxy_request_count` 统计的是所有进入普通代理分支的请求
     - `inspected_response_count` 只统计真正进入检查逻辑的响应
     - 像 `/v1/models` 这类未纳入 `endpoints` 检查范围的透传请求会进入代理总数，但不会进入被检查总数
   - 处理：
     - `renderLogs()` 改为统一走 `formatTimestamp()`
     - 新增运行期统计：
       - `bypassed_proxy_request_count`
       - `bypassed_proxy_path_counts`
       - `failed_proxy_request_count`
     - 在“运行状态”脚注里明确展示：
       - 总数计算口径
       - 当前差值
       - 未纳入检查的透传路径分布
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“实时日志应显示与系统时间一致的本地时间”断言
       - 新增“运行状态脚注应提示未纳入检查的透传路径”断言
       - 新增“代理请求总数与被检查响应总数的差值应能由透传请求和失败请求解释”断言

22. 管理页差值在慢请求进行中会继续放大，但页面之前没有把“进行中的代理请求”单独解释出来
   - 现象：
     - `代理请求总数` 与 `被检查响应总数` 的差值不只出现在透传或失败请求场景
     - 当普通代理请求仍在执行中时，差值会临时增大，但页面之前无法说明来源
   - 根因：
     - 缺少运行期 `active` 统计
     - `proxyRequest()` 也没有把普通代理请求生命周期包进开始/结束计数
   - 处理：
     - 新增运行期统计：
       - `active_proxy_request_count`
       - `active_proxy_path_counts`
     - 在普通代理请求进入后立刻记 `active start`
     - 无论成功、旁路、流式、非流式还是失败，都在 `finally` 里记 `active end`
     - “运行状态”脚注改成：
       - `代理请求总数 = 被检查响应总数 + 未纳入检查的透传请求 + 失败请求 + 进行中的代理请求`
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“代理请求进行中时应记录 active_proxy_request_count”断言
       - 新增“代理请求进行中时应记录 active_proxy_path_counts”断言
       - 新增“代理请求结束后 active_proxy_request_count 应回到 0”断言

23. 声明一致率把 `unknown` 也算进分母，导致百分比与“不一致次数 / 可疑样本”口径互相打架
   - 现象：
     - 管理页里“声明一致率”可能不是 `100%`
     - 但“声明不一致次数”仍然是 `0`
     - 最近可疑样本也没有 `model_family_mismatch`
   - 根因：
     - 一致率此前按：
       - `matched / total_checked`
     - 其中 `unknown` 表示本次没有拿到可比对的上游声明，它不该被计入“不一致”，却被错误计入了一致率分母
   - 处理：
     - 一致率改为只按已声明样本计算：
       - `matched / (matched + mismatched)`
     - `unknown` 继续单独保留，但不再拉低一致率
     - 管理页文案补充“未声明样本不计入分母”
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“声明一致率应只按已声明样本计算”断言
       - 新增 `gpt-5.4` / `gpt-5.5` 家族一致率排除 `unknown` 断言

24. 网关重启后管理页会把上一次会话的旧日志继续留在页面里，导致“实时日志时间仍不对”
   - 现象：
     - 网关已重启、`started_at` 已变成新会话
     - 但“实时日志”区域仍可能保留上一轮会话里的旧文本
     - `logsMeta` 会显示新的日志总数，`logsOutput` 却还是旧内容
   - 根因：
     - 管理页日志轮询依赖 `since_seq`
     - 网关重启后，新的日志序号会从小值重新开始
     - 页面若继续沿用旧的 `lastLogSeq` 做增量请求，会拿不到完整新日志
     - 旧页面内容因此不会被替换
   - 处理：
     - 页面保存上一轮 `metrics.started_at`
     - 检测到 `started_at` 变化后，立即清空增量游标并全量重拉日志
     - 若增量响应里的 `latest_seq` 小于当前游标，也自动回退为全量重拉
     - 管理页 HTML 与管理接口统一补 `cache-control: no-store`
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“网关重启后实时日志应重新全量加载并显示本地时间”断言
       - 新增“网关重启后不应继续保留上一次会话的旧日志”断言
       - 新增“检测到网关重启后应全量重拉日志”断言

25. 新增主动探针运行层，并与普通代理统计完全隔离
   - 目标：
     - 在不干扰 `proxyRequest()` 主链路的前提下，低频主动验证 `gpt-5.4` / `gpt-5.5` 声明契约
   - 处理：
     - 在 `gateway.mjs` 内新增 `active_probe` 配置和独立 `probeMonitor`
     - 新增主动探针状态快照 `active_probe`
     - 新增低频定时调度，不进入普通代理请求统计
   - 当前范围：
     - 长上下文硬契约探针
     - `gpt-5.5` 图片输入硬契约探针
     - 响应结构辅助探针
     - 身份一致性辅助探针
     - 训练截止日期 / 知识表现辅助探针
   - 边界：
     - 只做声明证伪，不做真实底层模型归因
     - 辅助探针默认只产出 `warning`
     - `transport_error` 不计入违约
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增 probe-only gateway 的 `violation` 断言
       - 新增 probe-only gateway 的 `warning` 断言
       - 新增“主动探针不应污染普通代理统计”断言

26. 管理页新增“主动探针”面板，并展示独立样本与日志证据
   - 现象：
     - 之前状态接口已有 `active_probe`，但管理页没有对应展示区域
   - 处理：
     - 新增主动探针概览卡片：
       - 状态
       - 最近目标模型
       - 最近一次运行
       - 通过 / warning / 违约 / transport error 次数
     - 新增最近主动探针样本表与日志证据
   - 验证：
     - `scripts/test-gateway-e2e.mjs`
       - 新增“主动探针状态未正确展示”相关 UI 断言
     - `scripts/test-install-restore.mjs`
       - 新增管理页包含“主动探针”与状态接口暴露 `active_probe` 断言

27. 管理页模板字符串里直接写反引号文案会让 gateway 启动即崩
   - 现象：
     - 新增“主动探针”说明文案后，`/__codex_retry_gateway/health` 超时
     - `node --check gateway.mjs` 报：
       - `SyntaxError: Unexpected identifier 'warning'`
   - 根因：
     - 管理页 HTML 本身位于 JS 模板字符串中
     - 文案里直接写了反引号包裹的 `warning` / `violation` / `transport_error`
     - 导致模板字符串被提前截断
   - 处理：
     - 把该段文案改成普通文本，不再在模板字符串里直接嵌反引号
   - 验证：
     - `node --check .\\gateway.mjs`
     - `node .\\scripts\\test-gateway-e2e.mjs`

28. 真实上游的长上下文主动探针使用大量唯一编号词，会把请求体打得过碎，导致探针极慢甚至先拿到 `502`
   - 现象：
     - 假上游 E2E 全绿
     - 但真实 `ai.input.im` 上，`gpt-5.4` 长上下文探针可能耗时接近 100 秒，甚至返回 `502`
     - 同一条探针改成高密度重复词后，可在几秒内正常返回 `200`
   - 根因：
     - 旧版 `buildLongContextProbeText()` 生成的是 `w000001`、`w000002` 这类大量唯一词
     - 真实上游在分词/前置服务处理这种超高基数输入时，负担远大于“相同 token 重复”的正常长上下文场景
     - 结果把本应用来验证 400K/900K 契约的探针，先打成了“上游服务暂时不可用”
   - 处理：
     - 长上下文探针改为高密度重复 `a` token
     - 仍保持总量超过 400K 级别，但避免因为输入构造方式本身制造伪 `502`
   - 验证：
     - `node .\\scripts\\test-gateway-e2e.mjs`
     - 真实本机路由 `POST /__codex_retry_gateway/api/probe/run`
       - `gpt-5.4 long_context` 从慢速 `502` 变为快速 `200 pass`

29. 主动探针样本之前只保留了 `start` 日志，且 `401/502` 这类上游错误摘要没有落进样本
   - 现象：
     - 管理页“最近主动探针样本”里的“查看”经常只能看到开始日志
     - `401`、`502 upstream_error` 等真实证据没有保留下来
     - `现在探测一次` 还会一直等待整轮探针跑完，真实上游慢时很像按钮卡死
   - 根因：
     - `collectProbeEvidenceLogs()` 在结果日志写入前就被调用
     - `error_excerpt` 只记录 `requestError`，不会从 HTTP 错误响应体提取摘要
     - `/api/probe/run` 同步等待 `safeRunActiveProbeOnce()` 全部完成后才返回
   - 处理：
     - 为主动探针样本补充：
       - `finish ... status=... result=... confidence=...`
       - `detail=...` 错误摘要
     - `error_excerpt` 改为优先保留响应体里的 `error.type/code/message` 或文本摘要
     - `/api/probe/run` 改为后台启动探针，立即返回 `202`
   - 验证：
     - `node .\\scripts\\test-gateway-e2e.mjs`
     - `powershell -ExecutionPolicy Bypass -File .\\scripts\\test-install-restore.ps1`
     - 真实本机路由状态接口：
      - `image_input` 样本可见 `upstream_error | Upstream access forbidden, please contact administrator`
      - `gpt-5.5 long_context` 样本可见 `upstream_error | Upstream service temporarily unavailable`

30. 流式 / 非流式拦截目标拆分后，命中统计不能等同于实际拦截统计
   - 现象：
     - 用户需要三种模式：
       - 仅拦流式
       - 仅拦非流式
       - 流式 + 非流式都拦
     - 如果只用旧的 `matched_response_count`，页面无法区分“命中了但当前配置只观察”和“命中了并实际拦截”
   - 根因：
     - 旧配置只有 `stream_action` 与 `non_stream_status_code`
     - 旧统计只有规则命中总数，没有按流式 / 非流式拆分，也没有 blocked 统计
     - 非流式命中被拦截时如果提前返回，模型一致性收口会漏掉这批响应
   - 处理：
     - 新增配置：
       - `intercept_streaming`
       - `intercept_non_streaming`
     - 默认双开，保持旧行为兼容
     - 后端和管理页都禁止两个开关同时关闭
     - 新增统计：
       - `matched_streaming_count`
       - `matched_non_streaming_count`
       - `blocked_response_count`
       - `blocked_streaming_count`
       - `blocked_non_streaming_count`
     - `matched_response_count` 继续表示规则命中次数，不改成实际拦截次数
     - 命中但未拦截时日志写 `action=observe_only`
     - 非流式命中无论拦截还是透传，都进入 `finalizeModelInsights()`
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
     - `node .\scripts\test-install-restore.mjs`
     - `node --check .\gateway.mjs`
     - `git diff --check`

31. 上游 API 不可用时不应刷网关内部错误堆栈
   - 现象：
     - 日志反复出现：
       - `[retry] upstream fetch failed attempt=1 ...`
       - `[error] TypeError: fetch failed`
     - 用户确认这类报错来自上游 API 异常，不是 gateway 自身逻辑崩溃
   - 根因：
     - 统一 catch 把重试后仍失败的上游 `fetch failed` 当成普通 gateway 内部错误记录
     - 结果日志里出现大段堆栈，容易误判为本地网关问题
   - 处理：
     - 保留一次轻量重试
     - 重试后仍失败时继续返回 `502`
     - 响应错误类型改为：
       - `type=upstream_error`
       - `code=upstream_fetch_failed`
     - 日志改为摘要：
       - `[upstream-error] fetch failed after retry path=... message=fetch failed`
     - 其他未知错误仍继续记录 `[error]` 堆栈
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
       - 新增连续上游 fetch failed 返回 `upstream_error` 断言
       - 新增日志不包含 `[error] TypeError: fetch failed` 断言

32. 管理页运行状态移除旧 516 专属卡片，改为实际拦截口径
   - 现象：
     - 用户希望删除 `516 命中次数`
     - `当前规则命中总数` 放到原 `516 命中次数` 位置
     - `516 占比` 改为 `实际拦截占比`
     - `实际拦截总数` 放到原 `516 占比` 位置
   - 根因：
     - 拦截目标拆成流式 / 非流式后，`516` 专属统计不再是管理页最核心口径
     - 用户真正关心的是当前规则命中、实际拦截总数和实际拦截占比
   - 处理：
     - 管理页移除 `516 命中次数` 与 `516 占比` 卡片
     - 运行状态卡片顺序调整为：
       - 当前规则命中总数
       - 实际拦截总数
       - 实际拦截占比
     - `实际拦截占比 = blocked_response_count / inspected_response_count`
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
     - `node .\scripts\test-install-restore.mjs`

33. 管理页运行状态脚注会把大量透传路径完整展开，导致 UI 爆长
   - 现象：
     - 当 gateway 代理真实前端站点时
     - `运行状态` 脚注会把 `/assets/*`、`/login`、`/logo.png`、`/api/v1/settings/public` 等透传路径全部平铺出来
     - 整块说明文字会被撑得很长，阅读体验很差
   - 根因：
     - 管理页脚注里的 `formatPathCounts()` 直接把所有路径计数 `join('，')`
     - 没有做条目数收敛或摘要化
   - 处理：
     - 保留路径分布提示，但只展示按次数排序后的前 `3` 项
     - 剩余条目统一收敛成 `其余 N 项`
     - 进行中的代理请求路径说明继续保留，不改统计口径
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
       - 新增“运行状态脚注应对过多透传路径做摘要收敛”断言
       - 新增“不应把所有透传路径完整展开”断言
       - 新增“进行中的代理请求路径仍应展示”断言
     - `node --check .\gateway.mjs`
     - `git diff --check`

34. 请求体超过本地上限时不应误记成 gateway 内部错误
   - 现象：
     - 日志出现：
       - `[error] Error: 请求体超过限制: 104857600 bytes`
     - 用户容易误判成 gateway 自身崩溃或上游异常
   - 根因：
     - `readRequestBody()` 超限时直接抛普通 `Error`
     - 顶层统一 catch 会把它按通用 `502 gateway_error` 和 `[error]` 堆栈收口
   - 处理：
     - 为请求体超限增加单独错误语义：
       - HTTP `413`
       - `type=gateway_rejection`
       - `code=request_body_limit_exceeded`
     - 日志改为摘要：
       - `[gateway-reject] request body too large path=... limit=... message=...`
     - 继续计入 `failed_proxy_request_count`
   - 额外修正：
     - 原默认 `request_body_limit_bytes = 10MB` 会挡住真实 Codex 大上下文请求
     - 默认值上调到 `100MB`
     - 安装脚本和复用迁移会把旧默认 `10MB` 自动升级到新默认
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
       - 新增“超限请求体应返回 413”断言
       - 新增“超限请求体应返回 request_body_limit_exceeded”断言
       - 新增“超限请求体应记录为 gateway-reject 摘要日志”断言
       - 新增“不应记录 [error] Error: 请求体超过限制”断言
     - `node --check .\gateway.mjs`
     - `git diff --check`

35. state 声称已安装不等于 provider 正在接管，配置迁移失败也不能把原健康 gateway 留在停止状态
   - 现象：
     - 电脑断电或外部 provider 工具改写后，`state.json` 仍存在，但 Codex `base_url` 可能已经绕过 gateway。
     - 重复运行启动入口会无条件重写配置或重启健康 gateway。
     - PID 文件指向存活进程时，如果该进程不是健康 gateway，旧逻辑仍可能误判为已运行。
     - PID 复用或陈旧 PID 指向无关存活进程时，旧重启逻辑会直接终止该进程。
     - `latest_backup_path` 为空时重新接管，后续“恢复原配置”没有可用恢复点。
     - 切换到新的真实 provider 时，旧逻辑会复用上一 provider 的有效备份，导致恢复到错误 provider。
     - `latest_backup_path` 指向目录时，旧恢复逻辑会先停止 gateway，再在复制阶段失败。
     - state 仍在但 gateway `config.json` 丢失时，退回安装分支会把已经指向 gateway 的 Codex 配置误存成恢复点。
     - `config.json` 丢失且旧 gateway 仍健康时，失败迁移会遗留新配置或丢失健康实例的 PID 管理状态。
     - 直接调用 install 时仍走独立旧逻辑，无法复用 launch 的运行时配置恢复和回滚事务。
     - start 未指定 restart 时只要 PID 存活就直接返回，陈旧 PID 会阻止真正启动。
     - stop/restore 在 `config.json` 丢失时无法验证进程，却会删除 PID/state 并留下占端口的孤立 gateway。
     - 新进程健康等待只看 HTTP 200，可能接受另一进程返回的 health。
     - 新 child 保持存活但 health 超时/身份不匹配时，start 抛错却不终止自己创建的 child；上层 stop 又因无法验证而拒绝终止，形成孤立进程。
     - PID 文件写入位于清理边界外时，写盘失败会在 health 验证前直接逃逸，同样留下无 PID 的 child。
     - 当前 provider 与 state 记录的 provider 不一致时，旧逻辑仍可能借用另一 provider 的 `original_base_url`。
     - 迁移 listen 地址后若新端口启动失败，旧健康 gateway 已被停止，文件虽然回滚但服务没有恢复。
   - 根因：
     - 安装身份、provider 当前接管状态、gateway 配置迁移需求与进程健康状态被混成一个布尔判断。
     - 回滚按整个 `catch` 粗粒度重写所有文件并停止进程，没有记录本次实际发生的写入和生命周期动作。
     - 备份逻辑只覆盖首次安装，没有区分“provider 指向真实上游”与“provider 已指向已管理 gateway”。
     - 退回安装分支时没有再次校验 state 的 provider 身份，Node 还只检查备份路径存在，没有确认它是普通文件。
   - 处理：
     - 安装身份按 `provider_name + codex_config_path + state/config` 判断；provider 漂移只恢复 `base_url`，不替换既有 upstream。
     - gateway 运行状态同时检查 PID 与 health；健康且配置无变化时保持文件字节、mtime、PID 和备份目录不变。
     - health 返回当前 `process_id`；只有它与 PID 文件一致时才允许停止进程，无法证明身份时只移除陈旧 PID。
     - 手工 install 作为 launch 的无 UI 包装，首次安装写入函数只由 launch 判定后内部调用，不再维护第二套恢复控制面。
     - start 无论是否要求 restart 都先校验 PID 与 health 身份；身份不匹配时只移除 PID 并继续启动。
     - stop/restore 在磁盘配置缺失时使用 state 的 gateway 地址读取 status，并再次绑定 PID；无法验证时抛错且保留 PID/state。
     - 启动后的 health 等待接收新 child PID，只有响应 `process_id` 匹配才返回成功。
     - start 从 PID 文件写入开始包进本地事务；写入、child 存活检查或 health 等待失败时直接终止自己创建的 child并等待退出。
     - 只有复查确认 child 已退出且 PID 文件仍等于该 child PID 时才删除；强制终止后仍存活则保留 PID，再重新抛出原始启动错误。
     - provider 指向真实上游且备份缺失/不可用时，接管前创建一次真实配置快照并写回 state；切换 provider 时强制创建当前 provider 的独立恢复点；provider 已指向 requested/state/config 中任一已管理 gateway 时不创建伪备份。
     - state 存在但 gateway 配置丢失时可以按已知 `original_base_url` 重建配置；旧 gateway 仍健康时优先从绑定 PID 的状态接口取回运行时配置并进入 reuse 事务；只有 provider 身份与配置路径匹配时才允许借用该 upstream。
     - 备份路径必须是普通文件；目录或失效路径在停止 gateway 前直接拒绝。
     - 配置迁移使用动作级回滚，只恢复本次实际写过的文件；启动失败时清理失败实例，恢复旧配置，并在旧实例原本健康时重新拉起。
   - 验证：
     - `node .\scripts\test-launch-ui.mjs`
       - 覆盖重复启动零写入、provider 漂移、直接 start/launch 的陈旧存活 PID 防误杀、错误 PID health 200 拒绝、PID 写失败与启动验证失败的 child/PID 清理、跨 provider 备份隔离、目录恢复点拒绝、缺失配置失败迁移和旧健康实例恢复。
     - `node .\scripts\test-launch-ui-unix.mjs`
       - 对 Unix/Node 管理核心执行同构场景。
     - `node .\scripts\test-install-restore.mjs`
       - 验证首次备份、手工 install 复用 launch 控制面、配置丢失重建、provider 身份与备份隔离、缺失配置 restore 进程收口、目录恢复点和恢复闭环未回归。

36. 主动探针不能把一个模型的 reasoning effort 画像无条件套给所有目标模型
   - 现象：
     - 最近真实请求为 `gpt-5.6-terra / ultra` 后，五模型主动探针会给 5.4、5.5 和 `gpt-5.6-luna` 也发送 `ultra`。
     - 上游可能因 effort 超出目标模型能力返回 `400`，探针再把该错误误当成模型契约违约证据。
   - 根因：
     - `activeProbeRequestProfile` 只有一个全局 effort，`applyActiveProbePayloadProfile()` 没有结合 payload 的目标模型做能力约束。
     - 被动采集支持完整 effort 集合与主动探针合法出站参数被混成同一集合。
   - 处理：
     - 被动采集继续完整接受 `minimal / low / medium / high / xhigh / max / ultra`。
     - 主动探针出站按目标家族约束 effort：5.4/5.5 为 `low..xhigh`，5.6 sol/terra 为 `low..ultra`，5.6 luna 为 `low..max`。
     - 长上下文探针日志记录最终实际发送的 effort，不再记录裁剪前画像。
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
       - 覆盖 5.6 三变体 × `minimal..ultra` 全采集矩阵、相似模型前缀隔离和公式模式跨模型 516/1034。
       - 先证明五模型请求全部错误继承 `ultra`，再验证各目标模型收到自己的合法上限值，并验证 `minimal` 统一按探针下限裁剪为 `low`。

37. AGOS 测试治理矩阵的 Root 应指向 rules component，不是产品仓根
   - 现象：
     - `generate-test-governance-matrix.ps1 -Root D:\Android_source\ai-growth-os` 报 `test governance profiles missing`。
   - 根因：
     - 该脚本把 `-Root` 解释为 rules root，并固定读取 `<Root>\registry\test-governance-profiles.yml`。
   - 处理：
     - 使用 `-Root D:\Android_source\ai-growth-os\components\rules`。
   - 验证：
     - 报告返回 `TEST_MATRIX_STATUS=ready`、`SIBLING_REGRESSION_GUARD_STATUS=passed` 和 `TEST_GOVERNANCE_MATRIX_OK`。

38. 严格 reasoning 全流缓冲会把客户端首字时间拖到接近响应完成，直接透传与超时改写必须按是否已写客户端分流
   - 现象：
     - 上游已经持续产生 SSE，但客户端长时间看不到首个有效输出，观测上首字时间接近整轮完成时间。
     - 如果为降低延迟直接提前写响应头，后续命中规则、Capacity、429 或 timeout 时已无法安全改写为 `502`。
   - 根因：
     - 既有 strict reasoning 路径必须在完整解析后才能判断 token/结构命中，因此会缓存整轮 SSE。
     - 上游首 chunk、首 content 与客户端首写是三个不同时间点；旧采集没有完整区分。
     - HTTP 响应一旦开始透传，状态码和已写字节不可撤回，不能在同一响应里重新派发并拼接第二轮结果。
   - 处理：
     - `intercept_rule_mode=none` 禁用 reasoning 命中、续写和专用剥离，未启用 latency guard 时直接边读边透传。
     - none + latency guard 只缓存首个有效输出前的 lifecycle/metadata，固定上限 `1MiB`；文字、commentary、final、tool/function call 才算 progress。
     - 总 deadline 从第一次上游派发开始并跨内部 attempt 保持不变；首 progress 重试与 reasoning、续写、Capacity、429 共用 `guard_retry_attempts`。
     - 未透传时 timeout 可返回稳定 `502`；已透传后只取消上游并断开连接，记录 `timeout_disconnected_after_forward`，不得伪装为 502。
     - analytics schema 升级为 `3`，补充 `policy_*`、`retry_*`、客户端首写、timeout 和 forwarding 字段；旧样本缺字段统一保持 `null`。
     - Windows/Unix 启动控制面保留合法 `none`、动作枚举和嵌套 `latency_guard`；旧 Capacity 布尔仅在新动作缺失时参与迁移，正确配置二次启动保持配置字节、mtime 和 PID 不变。
   - 验证：
     - `node .\scripts\test-gateway-e2e.mjs`
     - `node .\scripts\test-install-restore.mjs`
     - `node .\scripts\test-launch-ui.mjs`
     - `node .\scripts\test-launch-ui-unix.mjs`
     - `node --check .\gateway.mjs`
     - `node --check .\scripts\admin-lib.mjs`
     - PowerShell Parser AST 检查 `common.ps1`、`install-for-current-provider.ps1`、`launch-ui.ps1`
     - `git diff --check`

39. Retry-After 等待、客户端断连和前导缓冲必须在同一 attempt 内按最终事实收口
   - 现象：
     - 已完整收到 429 并进入 Retry-After 等待后，总 deadline 到期会从外层直接 `return`，客户端既收不到 502，也没有结束响应。
     - 该 attempt 在等待前已被落成 `http_429_internal_retry`，再次走 timeout 会产生重复或矛盾样本。
     - none + latency guard 会先把越界 chunk 压入前导数组，再发现已超过 `1MiB` 并刷新，因此固定值不是严格内存上限。
     - 客户端主动断开与上游断流共用 AbortError，若不先检查客户端信号会误记为 upstream terminated。
   - 根因：
     - 策略 handler 过早完成 retry 计数、模型统计和 attempt 样本，等待结果不再拥有可收口的原始 sample。
     - 外层只把 `waitForRetryDelay=false` 当作停止信号，没有区分 total timeout 与 client disconnect。
     - 前导缓冲在 push 后才比较累计字节数，单个网络 chunk 可以让数组瞬时越界。
   - 处理：
     - 策略 handler 只返回 retry 意图；等待真正完成后才记录策略 retry、扣共享预算并创建下一 attempt。
     - 等待被总 deadline 中断时，用同一未完成 sample 调用 timeout 收口并返回 `upstream-total-timeout` 502；客户端断开则记录 `client_disconnected`。
     - 前导 chunk 在 push 前计算累计值；将越界时先刷已有块，当前 chunk 直接写给客户端。
     - `endpoints` 作为 reasoning、Capacity、429、latency 的统一管理边界；timer 阈值限制为 `0..2_147_483_647`。
   - 防回归：
     - `node .\scripts\test-gateway-e2e.mjs` 使用两个独立临时网关做确定性故障注入，分别覆盖 deadline 中断等待和前导数组硬上限。
     - deadline 用例要求 HTTP 502、`upstream_total_timeout`、只发一次上游请求且只落一个 `total_timeout_returned_502` sample。
     - 缓冲用例要求大于 `1MiB` 的无 progress 元数据仍返回 200，并记录 `timeout_response_control_lost=true` 与 `response_forwarding_started=true`。

### 2026-06-26 实测证据

- 假上游 E2E
  - `test-gateway-e2e.ps1` 通过
  - 已验证 root 路径和 `/v1` 路径都能区分 `516` 与 `128`
- 安装/恢复闭环
  - `test-install-restore.ps1` 通过
  - 已验证 UI 页面、状态接口、日志接口、516 统计、热更新配置、UI 恢复闭环
- 一键启动入口
  - `test-launch-ui.ps1` 通过
  - 已验证首次启动自动安装、再次启动自动复用、UI 页面可达、默认 `516 -> 502` 规则仍生效
- Unix shell 入口
  - `test-launch-ui-unix.ps1` 通过
  - 已验证 `.sh` 入口能完成启动、透传、恢复闭环
- Bash 默认入口实机验证
  - `bash ./scripts/launch-ui.sh --no-open` 通过
  - 输出 `mode=reuse`
  - `GET /__codex_retry_gateway/health` 返回 `200`
  - `GET /__codex_retry_gateway/ui` 返回 `200`
  - `GET /v1/models` 返回 `200`，并继续透传到真实上游
- Bash 入口后的 `codex exec` 实机验证
  - 命令退出码 `0`
  - 最后一条消息文件返回 `OK`
- 当前真实 provider
  - 当前 Codex 配置里的 `base_url` 已可切到 `http://127.0.0.1:4610`
  - 当前 gateway 运行配置里的 `upstream_base_url` 会指向用户自己的真实上游
  - `GET /__codex_retry_gateway/health` 返回 `ok=true`
  - `GET /v1/models` 已经经本地 gateway 成功透传到真实上游
  - `GET /__codex_retry_gateway/ui` 已实机打开，页面显示当前 upstream、provider、config 路径和 516 规则
- 真实 `codex exec`
  - gateway 停止时，CLI 真实提示：
    - `url: http://127.0.0.1:4610/responses`
    - 并自动进入 `Reconnecting...`
  - gateway 恢复后，`codex exec` 在临时目录再次成功返回 `OK`

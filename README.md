# Codex Retry Gateway

TG群：[https://t.me/AI_INPUT_IM](https://t.me/AI_INPUT_IM)

一个不依赖 `cc-switch` 路由模式的独立本地网关。

项目真源说明：

- 如果你想看“这个项目当前代码到底负责什么、请求链路怎么走、统计口径怎么算、主动/被动探针边界在哪里”，优先看：
  - `docs/superpowers/specs/2026-06-28-project-source-of-truth.md`

目标：

- 保持 Codex 继续使用现有 `auth.json`
- 只把 `config.toml` 的当前 provider `base_url` 改成本地网关
- reasoning 观测精确区分 `gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`，并接受 `minimal / low / medium / high / xhigh / max / ultra` 思考等级；三个 5.6 模型不会折叠成同一个统计键
- 非流式默认按 `518*n - 2` 公式匹配 `reasoning_tokens = 516 / 1034 / 1552 / 2070...`，命中后先在网关内部重试，超过上限后才返回 `502`
- 流式在 `reasoning_tokens` 主规则命中时默认使用 Responses 安全续写恢复；网关会把多次安全续写折叠成一个下游 SSE：命中轮 lifecycle / reasoning / final answer / message / tool call 均视为不可信并丢弃，最终只透出干净完成轮自带的 lifecycle 与输出；命中会继续安全续写，最多尝试 `guard_retry_attempts` 次，耗尽后仍命中才返回 `502`
- 拦截规则默认并推荐 `reasoning_tokens` 长度模式；`final_answer_only_high_xhigh` 仅作为实验收窄规则；续写恢复是流式命中动作，不是拦截规则本身
- `final_answer_only_high_xhigh` 排除普通 `reasoning_tokens=0`，这类样本只观察落盘；`reasoning_tokens=null/缺失` 或非 0 的 high/xhigh final answer only 仍可命中实验规则
- `stream_action=continuation_recovery` 是默认流式命中动作，不是单独的拦截规则。命中样本仍由 `intercept_rule_mode` 和 `reasoning_match_mode` 决定：默认公式模式匹配 `516、1034、1552、2070...` 这类所有 `518*n - 2` 值；仅当 `intercept_rule_mode=reasoning_tokens` 且 `/responses` 或 `/v1/responses` 的流式响应命中时尝试续写恢复，使用 `guard_retry_attempts=5` 控制最大内部尝试次数；`final_answer_only_high_xhigh` 实验规则即使选择该动作，也只共用 `guard_retry_attempts` 做普通内部重试/最终拦截；续写请求会删除 `previous_response_id`，只显式 replay 原始 input 并追加 `phase=commentary` 标记，默认不自动请求 `reasoning.encrypted_content`，续写 replay 会过滤原始 input 中的 reasoning item / `encrypted_content`，安全模式下即使原请求显式 include 且本轮未命中，也会在下游响应和本地请求摘要中剥离 `encrypted_content`，也不 replay 命中轮 encrypted reasoning item；每次命中都会继续安全续写，最多尝试 `guard_retry_attempts` 次；多次安全续写会折叠为一个 coherent downstream SSE，中间轮的 reasoning item / tentative final answer / message / tool call、`response.completed` 和 `[DONE]` 不会透给客户端；耗尽后仍命中才返回拦截状态
- 管理页运行状态会实时展示续写恢复效果：`续写次数` 记录本次启动以来触发 Responses 流式续写恢复的次数，`续写成功率` 按成功透传的客户端请求数 / 续写尝试次数计算，是偏保守的运行指标
- 只有显式 `context_compaction` 且 `reasoning_tokens=0` 的压缩响应可豁免拦截；`remote_compaction_v2` 仅是 beta feature 标记，普通 turn 的 516/1034/1552 仍按 `reasoning_tokens` 主规则命中并内部重试
- `intercept_rule_mode=none` 会关闭 reasoning 命中、拦截、续写恢复和专用 encrypted content 剥离，正常流式响应直接透传，但请求与每次上游尝试仍进入全量统计
- Capacity 与通用 HTTP 429 是独立于 reasoning 规则的可叠加策略，分别支持原样透传、直接转 502、重试后透传、重试后 502；精确 Capacity 特征优先于同一响应上的通用 429
- 响应超时保护默认关闭；启用后可分别约束首个有效输出与整个客户端请求的总耗时，首 progress 重试与 reasoning、续写、Capacity、429 共用 `guard_retry_attempts`
- 默认同时拦截 root 路径和 `/v1` 路径：
  - `/responses`
  - `/chat/completions`
  - `/v1/responses`
  - `/v1/chat/completions`

限制：

- 这个网关不负责 `Responses` 和 `Chat Completions` 协议互转
- 如果你的上游本身不支持 Codex 当前使用的协议，这个网关不会替你补齐转换能力
- 这个网关是本机单进程代理，适合 Codex 本地路由与少量并发请求，不定位为公网高并发反向代理

## 默认路径

Windows:

- Codex 配置：`%USERPROFILE%\.codex\config.toml`
- Gateway 状态目录：`%USERPROFILE%\.codex-retry-gateway`

macOS / Linux:

- Codex 配置：`~/.codex/config.toml`
- Gateway 状态目录：`~/.codex-retry-gateway`

## 当前版本说明

- 这是一个可独立发布、独立运行的仓库
- 默认监听地址是 `http://127.0.0.1:4610`
- 默认示例上游见 `config.example.json`
- 实际运行时配置会写到当前用户目录下的 gateway 状态目录

## 一键启动并打开管理页

在仓库根目录执行：

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launch-ui.ps1
```

macOS / Linux:

```bash
bash ./scripts/launch-ui.sh
```

这个脚本是默认入口，执行后会自动完成：

- 第一次运行时：
  - 备份当前用户目录下的 Codex `config.toml`
  - 生成当前用户目录下的 gateway `config.json`
  - 启动本地 gateway
  - 把当前 `model_provider` 对应的 `base_url` 改到本地 gateway
- 之后再次运行时：
  - 自动复用现有安装状态
  - 同时核对 provider、gateway 配置、PID 与 health；配置和健康状态都正确时不改文件、不重启进程
  - provider 被外部工具改走时只恢复 gateway 接管，不改现有 upstream、不重启健康 gateway
  - provider 指向真实上游且恢复备份缺失时，先保存一次当前真实 provider 配置；切换 provider 时为新 provider 建立独立恢复点，不复用旧 provider 备份；provider 已指向 gateway 时不会把 gateway 配置伪装成恢复点
  - PID 只有在 health 返回的 `process_id` 与 PID 文件一致时才视为受管 gateway；陈旧 PID 即使碰巧指向存活进程，也只清理 PID 文件，不终止无关进程
  - 手工 install 与一键 launch 共用同一套接管恢复控制面；直接 start 即使未指定 restart，也会先验证 PID 身份
  - gateway 停止或 PID 对应实例不健康时才重新拉起；配置需要迁移时才重启加载新配置
  - `config.json` 丢失但旧 gateway 仍健康时，从已验证进程的状态接口恢复运行时配置；迁移失败会恢复文件原始存在性和旧健康实例
  - stop/restore 在 `config.json` 丢失时会通过 state 地址重新绑定 PID；无法验证时保留 PID/state 并拒绝继续
  - 新进程只有在 health 返回自己的 `process_id` 时才算启动成功；其它进程返回 HTTP 200 也不会误判
  - 新 child 从 PID 写入开始就进入 start 的清理事务；PID 写入、存活检查或 health 验证失败时直接终止，并且只有确认退出后才删除仍属于该 child 的 PID 文件，不依赖上层 stop 补救
  - 恢复 Codex 原设置前会确认备份路径是普通文件，目录或失效路径不会先停止 gateway
  - 配置迁移启动失败时恢复修改前文件；迁移前实例健康时会按旧配置重新拉起
  - 自动再次打开管理页

默认会打开：

```text
http://127.0.0.1:4610/__codex_retry_gateway/ui
```

如果你只想启动、不自动开浏览器：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launch-ui.ps1 -NoOpen
```

```bash
bash ./scripts/launch-ui.sh --no-open
```

常用参数：

- Windows 参数：
  - `-CodexConfigPath`
  - `-StateRoot`
  - `-ListenHost`
  - `-ListenPort`
  - `-NoOpen`
- macOS / Linux 参数：
  - `--codex-config-path`
  - `--state-root`
  - `--listen-host`
  - `--listen-port`
  - `--no-open`

macOS / Linux 说明：

- 需要 `bash`
- 需要 `Node.js 18+`
- Unix 入口会调用跨平台 `node` 管理核心，不依赖 PowerShell
- 推荐显式使用 `bash ...sh`
- 这样即使目录是从 Windows 或压缩包复制过来、没有可执行位，也能直接运行

## 手工安装入口

如果你明确只想做脚本级安装，不想自动打开 UI，也可以直接执行：

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-for-current-provider.ps1
```

macOS / Linux:

```bash
bash ./scripts/install-for-current-provider.sh
```

## 如何恢复

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\restore-codex-config.ps1
```

macOS / Linux:

```bash
bash ./scripts/restore-codex-config.sh
```

这个脚本会：

- 停掉本地 gateway
- 用最近一次备份恢复当前用户目录下的 Codex `config.toml`
- 删除当前安装状态文件
- 如果 state 没有指向真实存在的备份文件，脚本会明确失败；不会用已经指向 gateway 的配置伪造恢复点

## 管理页面

页面入口：

```text
http://127.0.0.1:4610/__codex_retry_gateway/ui
```

页面里可以直接做这几件事：

- 打开顶部 `TG群：https://t.me/AI_INPUT_IM` 入口
- 看当前监听地址、真实上游、当前 provider、当前 Codex base URL
- 看本次 gateway 启动以来的实时统计
  - 代理请求总数
  - 被检查响应总数
  - 当前规则命中总数
  - 实际拦截总数
  - 实际拦截占比
  - 流式 / 非流式规则命中次数
  - 流式 / 非流式实际拦截次数
  - 续写次数
  - 续写成功率
- 看模型家族一致性统计
  - 本地请求模型占比
  - 上游声明模型占比
  - 流式声明模型占比
  - 声明一致率
  - `gpt-5.4`、`gpt-5.5`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` 分别统计，不折叠 5.6 变体
  - `400K` 家族异常次数
  - 单请求模型漂移次数
  - 疑似请求内重建/重试次数
- 看主动探针统计
  - 最近目标模型
  - 通过次数
  - warning 次数
  - 违约次数
  - transport error 次数
  - 最近主动探针样本与日志证据
- 看历史导入分析
  - 先做字段预检，展示 `analysis_value`、`conclusion` 和 `field_coverage`
  - 缺少核心 reasoning 行为字段时标记 `no_analysis_value`，不把纯历史聚合误当成特征证据
  - 后台聚合 CC Switch SQLite 历史请求
  - 后台聚合 Codex SQLite 日志关键词、等级和 target
  - 文件级索引 Codex session JSONL 大文件
  - 展示导入进度、数据源、请求量、token、延迟、日志行数和 session 体积
- 改 `reasoning_equals`
- 改 `reasoning_match_mode`：手动填写 `reasoning_equals`，或使用完整 `518*n - 2` 公式
- 改拦截规则模式：推荐 `reasoning_tokens`；`final_answer_only_high_xhigh` 仅用于短时实验和候选特征复盘；`none` 不使用 reasoning 规则并直接透传
- 改流式 / 非流式拦截目标
- 改 `stream_action`：标准保护、Responses 流式续写恢复、或兼容旧行为断开连接
- 改 `endpoints`
- 改 `non_stream_status_code`
- 改 `guard_retry_attempts`
- 分别设置 `capacity_error_action` 与 `http_429_action` 的透传、502 和内部重试动作
- 独立开启响应超时保护，并设置首个有效输出阈值、总耗时阈值和首 progress 超时动作
- 开关 `log_match`
- 动态查看当前 gateway 的实时日志
- 一键恢复 Codex 原设置

Issue #9 收口说明：

- 已增加 reasoning 行为统计大盘，包含 `reasoning_tokens` 高频排行，用于识别高频 reason token 作为候选特征值。
- 高频排行不是自动定性结论，只作为候选观察入口；后续判断仍应结合模型家族、`reasoning.effort`、final answer only、commentary observed、耗时 / TPS / token 规模归一化偏差一起看。
- 已补上下文压缩保护：只有显式 `context_compaction` 且 `reasoning_tokens=0` 的响应只观察和落盘；`null` 或其它 token 值仍按当前拦截规则处理。
- PR 合并后可关闭 GitHub Issue #9：`https://github.com/nonononull/codex-retry-gateway/issues/9`。

Issue #11 收口说明：

- 历史版本增加了 `retry_upstream_capacity_errors` 布尔开关；该字段现在只保留为旧配置兼容入口。
- 新配置以 `capacity_error_action` 为真源。旧值 `false` 迁移为 `pass_through`，旧值 `true` 或缺失迁移为 `retry_then_pass_through`。
- 通用 HTTP 429 不受旧 Capacity 布尔控制，改由独立的 `http_429_action` 管理；默认仍为 `pass_through`。普通非 Capacity 5xx 不会被泛化重试。
- PR 合并后可关闭 GitHub Issue #11：`https://github.com/nonononull/codex-retry-gateway/issues/11`。

说明：

- 页面保存配置后会立即热生效，不需要重启 gateway
- 页面点“恢复 Codex 原设置并关闭网关”后，当前页面会失联，这是预期行为
- 日常恢复优先用 UI；`restore-codex-config.ps1` 作为脚本级应急回滚入口保留
- UI 恢复不会再额外拉起恢复子进程，而是由当前 gateway 直接完成恢复并退出
- 统计口径默认按“本次 gateway 启动以来”累计
- 当前规则命中总数表示命中当前拦截规则的次数，不等于实际拦截次数；默认规则模式是 `reasoning_tokens`，命中值默认来自完整 `518*n - 2` 公式，也可切回手动 `reasoning_equals`；切到 `final_answer_only_high_xhigh` 后则按 high/xhigh 的 final answer only 结构计数并排除普通 `reasoning_tokens=0`；`none` 不产生 reasoning 规则命中，但仍完整采集；`stream_action=continuation_recovery` 只改变流式命中后的处理动作，不改变规则命中口径
- 实际拦截占比 = 实际拦截总数 / 被检查响应总数
- 关闭某一类拦截后，该类命中仍会继续计入规则命中与模型一致性观测，但不会计入实际拦截
- `guard_retry_attempts` 是单个客户端请求的共享内部追加尝试预算；reasoning 普通重试、Responses 续写恢复、Capacity、HTTP 429 和首个有效输出超时重试都会消耗同一预算
- 运行状态里的“续写次数”表示本次 gateway 启动以来实际触发 Responses 流式续写恢复的次数；“续写成功率”表示成功透传的客户端请求数 / 续写尝试次数
- 续写恢复命中后，命中轮会计入实际拦截；网关丢弃中间命中轮 lifecycle、reasoning item、tentative final answer、message、tool call、`response.completed` 与 `[DONE]`，最终只保留干净完成轮自带的 `response.created` / `response.in_progress` / `response.completed` / `[DONE]`；后续轮再次命中会继续安全续写，直到 `guard_retry_attempts` 耗尽；只有最终成功透传给客户端时，才计入续写成功，耗尽后仍命中则返回 `502`
- Capacity 只精确匹配 `Selected model is at capacity. Please try a different model.`；其余 HTTP 429 才进入通用 429 策略，普通非 Capacity 5xx 继续原样透传
- HTTP 429 重试会遵守秒数或 HTTP-date 格式的 `Retry-After`，单次等待最多 60 秒；无合法 header 时使用 full-jitter，等待超过总 deadline 时直接执行当前动作的耗尽分支
- 已进入 Retry-After 等待后如果总 deadline 到期，timeout 优先并用当前 attempt 返回 `upstream-total-timeout` 502，不会重复落样本或创建新 attempt；客户端在等待中断开时只记录 `client_disconnected`
- `endpoints` 是 reasoning、Capacity、HTTP 429 和 latency guard 的共同管理边界；未列入的路径完全旁路这些策略，不会出现只启用超时但不处理 Capacity/429 的半旁路
- `latency_guard.first_progress_timeout_ms` 与 `latency_guard.total_timeout_ms` 只接受 `0..2_147_483_647` 的整数；`0` 表示单独关闭该阈值，避免超过 Node 定时器上限后被缩短成近似立即超时
- 一旦响应头或不可撤回内容已经写给客户端，gateway 就不能把状态改成 502，也不能重新派发并拼接第二轮输出；后续总超时只能取消上游并断开连接，样本记录 `timeout_disconnected_after_forward`
- 网关内部重试的每次上游尝试都会计入代理请求总数；每次拿到并检查的响应都会计入被检查响应总数；命中当前拦截规则会计入当前规则命中总数，被吞掉重试或最终拦截会计入实际拦截总数
- 命中日志里的 `action=internal_retry remaining=N` 表示本次命中只在网关内部吞掉并继续重试，没有把失败状态返回给 Codex；`action=return_status_502` 才表示已经达到重试上限或配置为 `0`，本次会对 Codex 返回拦截状态
- `context_compaction` 样本会保留在大盘和导出里；只有实际豁免的 `reasoning_tokens=0` 样本会写入 `intercept_exempt_reason=context_compaction`，其它值仍会计入当前规则命中和实际拦截
- 模型家族一致性面板里的“上游模型”是上游自报
- “声明一致”不等于已证明真实运行一致
- “400K 家族异常”只表示行为上疑似不符合 `1M` 家族
- “单请求模型漂移”和“疑似请求内重建/重试”都按高风险展示
- “疑似请求内重建/重试”仅基于响应信号推断，不能直接确认缓存重建
- 主动探针默认关闭，并且与普通代理请求统计完全隔离
- 主动探针当前只做“声明契约证伪”，不做真实底层模型归因
- 主动探针目标可以分别选择 `gpt-5.4`、`gpt-5.5`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`；5.6 三个变体分别采集和展示
- 主动探针继承最近真实请求的 effort 时会按目标模型能力约束：5.4/5.5 为 `low..xhigh`，5.6 sol/terra 为 `low..ultra`，5.6 luna 为 `low..max`；这只影响主动探针出站请求，不裁剪普通请求的采集值
- 长上下文与 `gpt-5.5` 图片输入属于硬契约探针，可产出 `violation`
- 响应结构、身份一致性、训练截止日期 / 知识表现属于辅助探针，默认只产出 `warning`

## reasoning 行为统计后续路线

代码层已经完成第一阶段：全量采集、按日落盘、时间段大盘、JSON / CSV 导出、候选特征组合展示。
同时已补历史导入分析第一版：它独立于实时 reasoning analytics，只做后台聚合摘要，不把本地大库完整灌入实时日文件。

运行态注意：

- 如果本机 `127.0.0.1:4610` 还是旧 gateway 进程，新接口不会自动生效。
- 重新拉起或重启 gateway 后，才会开始写入 `%USERPROFILE%\.codex-retry-gateway\analytics\reasoning-behavior-YYYY-MM-DD.json`。
- 验证 `GET /__codex_retry_gateway/api/analytics/reasoning` 应返回 JSON；如果返回上游 HTML，说明当前运行实例没有加载 analytics 代码。
- 未经确认不要直接动正在承载 Codex 会话的路由进程。

后续不要把当前 `516` 全拦策略直接当成最终结论。`516` 只是高价值观察点，不等于“已确认降智”。真正要继续收敛的是这组组合特征：

```text
reasoning_tokens 异常值 + final_answer only + commentary_not_observed + 时序归一化偏差
```

海量数据分析口径：

- `gateway analytics` 是后续逐请求、逐重试、逐拦截的主事实源。
- `CC Switch` 日志和 `Codex session` 历史日志只做历史回填、字段探索和交叉校验。
- 实时特征分析通过 `/__codex_retry_gateway/api/analytics/reasoning/analyze` 读取 runtime analytics，并按统一 Profile `516_candidate_review_v1` 返回 `analysis_value`、`conclusion`、`field_coverage`、候选摘要和基线对比。
- 历史导入分析通过 `/__codex_retry_gateway/api/analytics/imports/run` 创建后台任务，通过 `/jobs/<job_id>` 轮询进度，通过 `/latest` 读取最近结果，通过 `/analyze` 对指定或最近 job 输出同口径分析结果。
- 历史导入第一版只聚合 CC Switch SQLite、Codex logs SQLite 和 Codex sessions JSONL 文件级索引；不会读取完整 prompt、完整 answer、Authorization 或 Cookie。
- 历史导入先跑 preflight；没有 `reasoning_tokens`、`final_answer_only`、`commentary_observed` 等核心字段时，结果为 `no_analysis_value`，可以保留摘要但不进入候选特征确认。
- 大盘优先看 rollup 聚合，明细只在时间段、模型、思考等级或候选特征下钻时读取。
- 面对 20GB 级 Codex session 历史日志，不做单进程全量 JSON 深解析；先用 `rg` / SQLite schema / key 扫描定位字段，再抽代表文件深解析。
- 导出默认按时间段输出 JSON / CSV；数据继续变大后必须走 rollup 优先、分页/分片、压缩包和每日索引，不让 UI 无边界深解析。
- 同步导出建议限制在 `31` 天以内；超过后创建后台导出任务，页面显示进度条和提醒，完成后再提供下载链接。
- 请求预览、失败摘要、响应摘要都必须截断和脱敏；CSV 默认只放结构字段、数值字段和状态字段。

516 分析口径：

- `普通观察 516`：命中 `reasoning_tokens=516`，但未同时满足候选复盘组合。
- `候选复盘 516`：`reasoning_tokens=516 + final_answer only + commentary_not_observed + 时序归一化偏差高`。
- `普通观察 516` 不等于确认正常，`候选复盘 516` 也不等于确认降智；两者都只是不同优先级的观察队列。
- UI 必须标注“516 只是观察点，不代表降智结论”，候选组合只能显示为“仅观察 / 候选复盘”。

后续优先级：

1. 继续扩充观测大盘，不改现有路由和拦截语义。
   - 补“普通观察 516 / 候选复盘 516”对比视图。
   - 补按 `gpt-5.4` / `gpt-5.5` / `gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna`、`reasoning.effort`、token 规模分层后的时序对比。
   - 补时序归一化偏差分布图，不把耗时、TPS、token 长度拆成单独判据。
2. 优化时序归一化算法。
   - 当前 `time_normalization_deviation` 只是第一版固定 baseline。
   - 后续应按模型家族、思考等级、输入/输出 token 规模建立动态基线。
   - 网络延迟、上游排队、首 token 延迟要单独保留，不要混成一个“耗时短”结论。
3. 增强导出与离线分析。
   - CSV 可以继续扩列，补更完整的流式时序、结构计数、模型声明、重试链路字段。
   - 后台导出任务已经支持按日期慢慢导出；后续再补每日 rollup、明细索引和压缩包导出，不急着引入数据库。
4. 做 observe-only 特征规则。
   - 先只标记候选，不进入拦截。
   - 规则形态可以从 `reasoning_tokens_outlier + final_answer_only + commentary_not_observed + time_normalization_deviation` 开始。
   - UI 要明确显示“仅观察”，避免误以为已经自动拦截。
5. 人工确认后再做特征拦截。
   - 只有当样本足够、误伤可解释、普通观察 516 和候选复盘 516 能稳定区分后，才考虑把 observe-only 规则升级为 intercept。
   - 现有 `reasoning_equals` 自定义拦截仍保留；`final_answer_only_high_xhigh` 作为可切换新模式，效果不好可以直接回退默认模式。

暂时不做：

- 不做自动“降智”判定。
- 不用单个 `reasoning_tokens` 值直接定性。
- 不用单独耗时阈值拦截。
- 不保存完整 prompt、完整 answer 或 Authorization。
- 不把主动探针样本混进真实代理请求统计。

## 如何调整拦截条件

编辑：

```text
Windows: %USERPROFILE%\.codex-retry-gateway\config\config.json
macOS / Linux: ~/.codex-retry-gateway/config/config.json
```

常用字段：

- `reasoning_equals`
  - 默认 `[516, 1034, 1552]`
  - 仅在 `reasoning_match_mode=manual` 时作为命中列表；公式模式下只保留为回退/参考列表
- `reasoning_match_mode`
  - 默认 `formula_518n_minus_2`
  - `manual`：手动填写 `reasoning_equals`
  - `formula_518n_minus_2`：按公式匹配 `reasoning_tokens >= 516 && (reasoning_tokens + 2) % 518 === 0`，会覆盖 `516、1034、1552、2070...`，不是只匹配默认前三个值
- `intercept_rule_mode`
  - 默认并推荐 `reasoning_tokens`
  - `reasoning_tokens`：稳定主规则，命中 `reasoning_equals` 即视为当前规则命中；真实使用中 516 拦截仍可能直接影响任务正确性
  - `final_answer_only_high_xhigh`：实验收窄规则，仅当 `reasoning.effort` 为 `high` / `xhigh`，响应结构是 `final answer only`、未观察到 commentary、无 tool call、无 reasoning item，且 `reasoning_tokens` 为 `null/缺失` 或非 0 时命中；普通 `reasoning_tokens=0` 只观察落盘，不触发该实验规则
  - `none`：不使用 reasoning 规则；不拦截、不续写、不做续写专用 encrypted content 剥离，正常流式响应直接透传，但继续全量采集并可叠加 Capacity、429 与超时保护
  - `max` / `ultra` 会完整进入采集、导出和分析分桶，但不会被名称为 `final_answer_only_high_xhigh` 的实验规则扩大匹配
  - 三个模式三选一；效果不确定或以任务正确性优先时，使用 `reasoning_tokens`
  - `request_kind=context_compaction` 只有在 `reasoning_tokens=0` 时豁免；`516/1034/1552` 等命中值仍按当前规则处理，并受 `guard_retry_attempts` 控制
- `continuation_marker_text`
  - 默认 `Continue thinking...`
  - `stream_action=continuation_recovery` 续写请求追加的 `phase=commentary` 标记文本
  - 当前管理页不单独提供输入框；可通过配置文件或配置 API 保存
- `intercept_streaming`
  - 默认 `true`
  - 控制流式响应命中当前拦截规则后是否真正拦截
- `intercept_non_streaming`
  - 默认 `true`
  - 控制非流式响应命中当前拦截规则后是否真正拦截
  - 使用 `reasoning_tokens` 或 `final_answer_only_high_xhigh` 时，`intercept_streaming` 与 `intercept_non_streaming` 不能同时为 `false`；`none` 模式允许二者同时关闭并在复用启动时原样保留
- `endpoints`
  - 默认包含 root 与 `/v1` 两套路径
- `non_stream_status_code`
  - 默认 `502`
- `guard_retry_attempts`
  - 默认 `5`
  - 表示单个客户端请求允许的最大内部追加尝试次数，不只用于 reasoning 命中
  - reasoning 普通重试、Responses 流式续写恢复、Capacity、HTTP 429 和首个有效输出超时重试共用这里，不会各自重新获得完整次数
  - `0` 表示不做内部尝试，直接按最终动作处理
  - 无上限，管理页保存后立即生效
- `capacity_error_action` / `http_429_action`
  - Capacity 默认 `retry_then_pass_through`；通用 HTTP 429 默认 `pass_through`
  - `pass_through`：不重试，原样返回上游状态与响应体
  - `return_502`：不重试，转换为 gateway 502
  - `retry_then_pass_through`：有共享预算时重试，耗尽后原样返回最后一次上游响应
  - `retry_then_502`：有共享预算时重试，耗尽后转换为 gateway 502
  - Capacity 精确特征优先于通用 429；通用 429 支持 `Retry-After`，普通非 Capacity 5xx 不进入这两个策略
- `latency_guard`
  - 默认 `enabled=false`；禁用时不创建策略超时计时器，`0` 表示单独关闭对应阈值
  - `first_progress_timeout_ms` 限制每次 attempt 等待首个有效输出的时间；lifecycle、心跳、元数据和 encrypted reasoning 不算 progress，非空文字、commentary、final answer、tool/function call 算 progress
  - `first_progress_action` 只允许 `return_502` 或 `retry_then_502`
  - `total_timeout_ms` 是从首次上游派发开始、跨所有内部 attempt 的硬截止线；触发后不再重试
  - 未透传时可安全返回 502；已经透传时只能终止连接并记录明确 timeout 动作
- `retry_upstream_capacity_errors`
  - 旧配置兼容字段，不再是新配置动作真源
  - `false` 且缺少 `capacity_error_action` 时迁移为 `pass_through`；`true` 或缺失时迁移为 `retry_then_pass_through`
- `stream_action`
  - 默认 `continuation_recovery`
  - `strict_502`：标准保护；命中当前拦截规则后在网关内重试，耗尽 `guard_retry_attempts` 后返回 `502`
  - `disconnect`：兼容旧行为；若命中发生在已透传 chunk 之后，则直接断开连接
  - `continuation_recovery`：仅当 `reasoning_tokens` 主规则命中时，对 Responses 流式请求优先尝试安全续写；续写次数同样受 `guard_retry_attempts` 控制，不限定特定 token 公式；续写请求删除 `previous_response_id`，只显式 replay 原始 input 并追加 commentary marker，默认不自动请求 `reasoning.encrypted_content`，续写 replay 会过滤原始 input 中的 reasoning item / `encrypted_content`，安全模式下即使原请求显式 include 且本轮未命中，也会在下游响应和本地请求摘要中剥离 `encrypted_content`，也不 replay 命中轮 encrypted reasoning item；多次安全续写会折叠成一个下游 SSE，避免客户端只看到最后一轮、收到多个 completed/DONE，或看到截断轮 reasoning/final/tool
  - `continuation_recovery` 只适用于 `reasoning_tokens` 主规则 + Responses 流式路径；`final_answer_only_high_xhigh`、Chat Completions、非流式响应不走续写恢复；达到尝试上限后仍命中时，会返回既有拦截状态
  - 运行状态里的续写成功率按 `continuation_recovery_success_count / continuation_recovery_count` 计算；`continuation_recovery_count` 是尝试次数，`continuation_recovery_success_count` 是最终成功透传的客户端请求数，没有触发续写时显示 `0.00%`
- `log_match`
  - 是否记录命中日志
- `active_probe.enabled`
  - 是否开启主动探针
- `active_probe.target_families`
  - 可分别选择 `gpt-5.4`、`gpt-5.5`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`
  - 三个 5.6 目标分别保存结果，不能用统一 `gpt-5.6` 名称覆盖真实变体
- `active_probe.endpoint_candidates`
  - 主动探针优先使用的上游路径
- `active_probe.long_context`
  - 长上下文硬契约探针配置
  - `target_input_tokens` 默认 `460000`，探针会按真实 `usage.input_tokens` 口径校准预算并落证据
- `active_probe.image_input`
  - `gpt-5.5` 图片输入硬契约探针配置
- `active_probe.response_structure`
  - 响应结构辅助探针配置
- `active_probe.identity_consistency`
  - 身份一致性辅助探针配置
- `active_probe.knowledge_cutoff`
  - 训练截止日期 / 知识表现辅助探针配置

改完后重启：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-gateway.ps1 -RestartIfRunning
```

```bash
bash ./scripts/start-gateway.sh --restart-if-running
```

如果你已经打开管理页，优先直接在页面里改；少数未暴露成页面输入项的字段，例如 `continuation_marker_text`，再通过 `config.json` 或配置 API 调整。

## 并发与日志写入

当前 gateway 是 Node.js 单进程异步 HTTP 代理：

- 可以同时处理多个 Codex 请求；每个请求都会独立读取请求体、请求上游、检查响应并更新统计。
- `guard_retry_attempts` 的内部重试是按单个客户端请求独立计算的，不会和其他并发请求共享重试次数。
- 日志写入使用同一个进程内 `WriteStream` 追加到日志文件；在当前单进程模型下，日志写入会按事件循环顺序排队，不会出现多进程同时抢写同一个日志文件的问题。
- UI 实时日志来自内存里的 `log_entries`，文件日志和 UI 日志都会记录同一类事件。

需要注意：

- 严格流式拦截模式会先缓存上游 SSE，再决定透传、内部重试或返回 `502`；并发流式请求多、响应很大时，内存占用会增加。
- `intercept_rule_mode=none` 且未启用响应超时保护时会边读边透传，不等待 `response.completed`；启用超时保护时只缓存首个有效输出前的 lifecycle/metadata，写入前严格检查固定上限 `1MiB`，将越界时先刷已有前导块并直接写当前 chunk，不会瞬时超限。
- 请求体会按 `request_body_limit_bytes` 先读入内存，默认限制是 `100MB`。
- 超过 `request_body_limit_bytes` 的请求会被本地 gateway 直接拒绝，并返回 `413 request_body_limit_exceeded`；这类情况不是上游故障。
- 当前 `log_entries` 是本次启动以来的内存累计；长时间高频运行会增加内存占用。
- 如果要把它放到公网或很高 QPS 场景，建议前面加成熟反向代理，并补日志轮转、内存日志上限、压测和进程守护。

## 其他机器如何应用

在其他 Windows 机器上：

1. 复制整个仓库目录
2. 确保本机有 `Node.js 18+`
3. 不需要安装 `cc-switch`，也不需要使用 `cc-switch` 路由模式
4. 在仓库根目录执行 `powershell -ExecutionPolicy Bypass -File .\scripts\launch-ui.ps1`
5. 如需回滚，优先在 UI 里点“恢复 Codex 原设置并关闭网关”；脚本级回滚仍可执行 `powershell -ExecutionPolicy Bypass -File .\scripts\restore-codex-config.ps1`

在其他 macOS / Linux 机器上：

1. 复制整个仓库目录
2. 确保本机有 `bash`
3. 确保本机有 `Node.js 18+`
4. 不需要安装 `cc-switch`，也不需要使用 `cc-switch` 路由模式
5. 在仓库根目录执行 `bash ./scripts/launch-ui.sh`
6. 如需回滚，优先在 UI 里点“恢复 Codex 原设置并关闭网关”；脚本级回滚仍可执行 `bash ./scripts/restore-codex-config.sh`

运行时状态默认写到当前用户目录：

```text
Windows: %USERPROFILE%\.codex-retry-gateway
macOS / Linux: ~/.codex-retry-gateway
```

## 已验证事项

- 本地 CI 为默认验收入口
  - 优先在本机运行 `test-gateway-e2e.ps1` / `test-install-restore.ps1` / `test-launch-ui.ps1` / `test-launch-ui-unix.ps1`
  - GitHub Actions `macos-smoke` 已在仓库侧手动禁用，push / PR 不再自动运行
  - 需要补足“本地没有 mac”时的 Unix 入口冒烟时，再按需手动重新启用或触发 `macos-smoke`
- `test-gateway-e2e.ps1`
  - 已通过
  - 验证 `/responses`、`/chat/completions`、`/v1/responses`、`/v1/chat/completions`
- `test-install-restore.ps1`
  - 已通过
  - 验证安装、透传、UI 页面、热更新配置、实时日志、516 统计、恢复闭环
- `test-launch-ui.ps1`
  - 已通过
  - 验证首次一键启动自动安装、再次启动自动复用、UI 可访问、默认 `516/1034/1552` 拦截仍生效
- `test-launch-ui-unix.ps1`
  - 已通过
  - 在当前 Windows 主机的 Bash 环境里验证 Unix `.sh` 入口能完成启动、透传、恢复闭环
- `bash ./scripts/launch-ui.sh --no-open`
  - 已通过
  - 当前机器实测返回 `mode=reuse`
  - 后续 `GET /__codex_retry_gateway/health`、`GET /__codex_retry_gateway/ui`、`GET /v1/models` 都返回 `200`
- `codex exec`
  - 已通过
  - 在 Bash 默认入口重新拉起 gateway 后，当前机器再次返回 `OK`
- 当前实机验证示例
  - `GET http://127.0.0.1:4610/__codex_retry_gateway/health` 已通过
  - `GET http://127.0.0.1:4610/v1/models` 已通过，并成功透传到配置里的真实上游
  - `GET http://127.0.0.1:4610/__codex_retry_gateway/ui` 已实际打开并确认页面内容
- `codex exec` 历史现象
  - gateway 关闭时，真实报错地址为 `http://127.0.0.1:4610/responses`
  - gateway 恢复后，`codex exec` 已再次成功返回 `OK`

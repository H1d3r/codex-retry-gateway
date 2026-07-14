# Session Plan

```yaml
schema_version: agos.session-plan.v1
architecture_contract_version: agos.brainstorming-gate.v1
task_id: crg-layered-gateway-policies
work_class: standard
task_summary: 增加 reasoning 直接透传模式，并把 Capacity、HTTP 429 与响应超时实现为可叠加独立策略。
project_root: C:\Users\dashuai\Documents\Playground\codex-retry-gateway-gpt56
trigger_source: user-approved-design-and-delivery-2026-07-14
decision_status: approved
approval_source: direct-user
approved_decision_ref: session-plan:crg-layered-gateway-policies#decision
superpowers_skill: superpowers:brainstorming
scope_hash: crg-none-capacity-429-latency-policy-v1
mutation_intent: source
allowed_operations:
  - read
  - edit
  - test
  - local-review
  - commit
  - push
  - pr
  - merge
executor_enforcement: tdd-shared-retry-budget-no-live-gateway-apply
selected_business_path: external-project-node-gateway-development
tracking_issue_ref: https://github.com/nonononull/codex-retry-gateway/issues/26
dependency_pr_ref: https://github.com/nonononull/codex-retry-gateway/pull/25
design_ref: docs/plans/2026-07-14-layered-gateway-policies-design.md
implementation_plan_ref: docs/plans/2026-07-14-layered-gateway-policies-implementation.md
runtime_workflow_ref: .ai-growth-os/runtime-workflows/crg-layered-gateway-policies.yml
```

## Approved Decision

- `intercept_rule_mode` 增加 `none`，只关闭 reasoning 拦截、续写和全流缓冲，继续全量采集。
- Capacity、通用 HTTP 429、首个有效输出超时和总 deadline 在任意 reasoning 模式下独立叠加。
- Capacity 与 429 使用四动作枚举；Capacity 优先于同一响应上的通用 429。
- 首个有效输出包含非空文字、commentary、final answer 与 tool/function call，不包含 lifecycle、心跳、元数据和 encrypted reasoning。
- 首 progress 超时可以按共享预算重试；总 deadline 跨 attempt 不重置，触发后不得重试。
- 已透传后禁止改写 502 或重新派发，只能断连并详细落盘。
- 所有策略重试与续写共用 `guard_retry_attempts`。

## Brainstorming

```yaml
level: standard
proposal_mode: parent-led-source-review
fallback_reason: 用户要求多 agent 放在实现后的同题代码审查；实现前由父线程完整读取源码、测试、README、build.md 与 err.md 后提出三方案并获得批准。
superpowers_skill: superpowers:brainstorming
actual_agent_count: 0
agent_result_refs: []
agent_budget_guard:
  initial_review_agents: 0
  escalation_agents: 0
  divergence: not-checked
  idle_agent_cleanup: checked
  timeout_policy: blocked-main-thread-rereview
  model_downgrade: forbidden
user_decision: approved-layered-independent-policies
decision_reason: 用户批准 reasoning 规则、Capacity、HTTP 429 与 latency guard 独立叠加，并批准文档、TDD、实现、重测、双 reviewer、PR 与合并交付链。
rejected_options:
  - scattered-conditionals-without-shared-policy-state
  - cross-request-provider-circuit-breaker-in-current-scope
verification_commands:
  - node .\scripts\test-gateway-e2e.mjs
  - node .\scripts\test-install-restore.mjs
  - node .\scripts\test-launch-ui.mjs
  - node .\scripts\test-launch-ui-unix.mjs
  - node --check .\gateway.mjs
  - node --check .\scripts\admin-lib.mjs
  - PowerShell AST parse changed scripts
  - git diff --check
```

## Assumptions And Uncertainty

- `exceeded retry limit, last status: 429 Too Many Requests` 通常是 Codex 客户端最终错误；gateway 应在更早阶段匹配每次上游 HTTP 429。
- 严格 reasoning 模式必须继续缓存完整流，none 模式才能真正降低客户端首字延迟。
- 429 无 header 时的 full-jitter 和过长 Retry-After 跳过重试是防放大约束，不是跨请求断路器。
- Node 原生 fetch/AbortController 足以实现，无需新增依赖。

## Local Knowledge Lookup

```yaml
local_knowledge_lookup:
  gbrain_queries:
    - codex retry gateway 首字延迟 总耗时 超时 502 熔断 内部重试
  gbrain_result: no-results
  vault_refs:
    - D:\Android_source\ai-growth-os\components\rules\rules\workflows\ai-growth-os-auto-application.md
    - D:\Android_source\ai-growth-os\components\rules\rules\workflows\ai-growth-os-brainstorming-gate.md
    - D:\Android_source\ai-growth-os\components\rules\rules\workflows\ai-growth-os-runtime-workflow.md
  rules_refs:
    - D:\Android_source\ai-growth-os\components\rules\rules\domain\agent-generated-code.md
    - D:\Android_source\ai-growth-os\components\rules\rules\quality\testing.md
  project_refs:
    - AGENTS.md
    - README.md
    - build.md
    - err.md
    - gateway.mjs
    - scripts/admin-lib.mjs
    - scripts/install-for-current-provider.ps1
    - scripts/launch-ui.ps1
    - scripts/test-gateway-e2e.mjs
    - scripts/test-install-restore.mjs
    - scripts/test-launch-ui.mjs
    - scripts/test-launch-ui-unix.mjs
  missing_coverage:
    - 本地脑库没有该项目的 latency guard 或通用 429 策略现成结论，当前源码、历史 err.md 与现有 E2E 作为事实源。
```

## Change Contract

```yaml
change_contract:
  target_contract:
    expected_behavior: reasoning none 模式真正流式透传；Capacity、429 和 latency guard 独立叠加并共享单请求重试预算。
    evidence_refs:
      - docs/plans/2026-07-14-layered-gateway-policies-design.md
      - https://github.com/nonononull/codex-retry-gateway/issues/26
  preserved_invariants:
    - name: reasoning-rule-contracts
      baseline_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      regression_ref: node .\scripts\test-gateway-e2e.mjs
    - name: detailed-attempt-telemetry
      baseline_ref: git:b4cac27:gateway.mjs
      regression_ref: node .\scripts\test-gateway-e2e.mjs
    - name: idempotent-windows-unix-recovery
      baseline_ref: git:b4cac27:scripts/test-install-restore.mjs
      regression_ref: node .\scripts\test-install-restore.mjs; node .\scripts\test-launch-ui.mjs; node .\scripts\test-launch-ui-unix.mjs
    - name: no-live-gateway-apply
      baseline_ref: user:2026-07-14-no-live-apply
      regression_ref: temporary process audit excludes 127.0.0.1:4610
  adjacent_surfaces:
    - name: streaming-http-state
      why_adjacent: writeHead/write/end、headersSent 与全流缓冲决定是否还能安全重试或返回 502。
    - name: abort-classification
      why_adjacent: 策略超时与普通 upstream stream terminated 都产生 AbortError，误分类会跳过重试或错误返回。
    - name: continuation-encrypted-content
      why_adjacent: none 模式必须禁用 continuation 专用剥离，但既有续写安全边界不能变化。
    - name: runtime-metrics-and-exports
      why_adjacent: 新策略动作必须进入实时计数与 JSON/CSV，不能破坏旧统计口径。
    - name: config-migration
      why_adjacent: Windows/Unix normalizer 会在复用启动时重写或补齐配置。
  historical_state_refs:
    - retry_upstream_capacity_errors legacy boolean
    - strict_502 and continuation_recovery full-stream buffering
    - old config without capacity_error_action/http_429_action/latency_guard
  stale_verdict_invalidation_refs:
    - 不使用规则仅等于 matched=false 的旧假设
    - 客户端首字时间等于 upstream time_to_first_content 的旧假设
  regression_checks:
    - surface: proxy-policy-and-protected-reasoning
      command_or_evidence_ref: node .\scripts\test-gateway-e2e.mjs
    - surface: install-restore-config-migration
      command_or_evidence_ref: node .\scripts\test-install-restore.mjs
    - surface: windows-launch-reuse
      command_or_evidence_ref: node .\scripts\test-launch-ui.mjs
    - surface: unix-launch-reuse
      command_or_evidence_ref: node .\scripts\test-launch-ui-unix.mjs
    - surface: syntax-and-format
      command_or_evidence_ref: node --check .\gateway.mjs; node --check .\scripts\admin-lib.mjs; PowerShell AST; git diff --check
  sibling_regression_guard:
    status: pending
    closeout_rule: passed-or-blocked-before-done
```

## Superpowers Method Discipline

```yaml
superpowers_method_discipline:
  upstream_superpowers_ref: https://github.com/obra/superpowers
  local_superpowers_state: unknown
  using_superpowers: superpowers:using-superpowers
  brainstorming: superpowers:brainstorming
  worktree_isolation:
    skill: superpowers:using-git-worktrees
    evidence: linked worktree C:\Users\dashuai\Documents\Playground\codex-retry-gateway-gpt56 on branch codex/passthrough-retry-timeout-policies
  planning_execution:
    writing_skill: superpowers:writing-plans
    executing_mode: parent-inline-bounded-batches
    plan_control_plane: project-native docs/plans and runtime workflow
  test_driven_development:
    skill: superpowers:test-driven-development
    cycle: RED/GREEN/REFACTOR
    evidence: red and green commands are written back to this session plan, runtime workflow and err.md
  verification_before_completion:
    skill: superpowers:verification-before-completion
    evidence: fresh four-E2E, syntax, PowerShell AST, process audit and diff evidence required before PR and merge
  systematic_debugging:
    skill: superpowers:systematic-debugging
    trigger: any unexpected RED/GREEN result, timeout race, process leak or reviewer finding
  code_review:
    request_skill: superpowers:requesting-code-review
    receive_skill: superpowers:receiving-code-review
    evidence: two same-question whole-branch reviewers after latest source mutation, followed by original-reviewer re-review for fixes
  finishing_branch:
    skill: superpowers:finishing-a-development-branch
    evidence: user preselected push, PR and merge after fresh verification and review gates
  evidence_writeback:
    target: build.md, err.md, session plan, runtime workflow and PR body
    docs_superpowers_boundary: docs/superpowers remains archive-only, not the active control plane
```

## TDD Contract

```yaml
tdd:
  skill: superpowers:test-driven-development
  red_required: true
  red_evidence_ref: Task1 2026-07-14 node scripts/test-gateway-e2e.mjs failed at 管理页缺少三种 reasoning 规则模式; node scripts/test-install-restore.mjs failed at missing capacity_error_action default; Task2 node scripts/test-gateway-e2e.mjs failed with none firstChunkAtMs equal completedAtMs; Task3 node scripts/test-gateway-e2e.mjs failed because capacity pass_through still retried under legacy boolean logic; Task4 node scripts/test-gateway-e2e.mjs failed for missing first-progress enforcement, policy counters, non-stream client timing, and 429 Retry-After first-progress timer isolation; Task5 node scripts/test-install-restore.mjs、test-launch-ui.mjs、test-launch-ui-unix.mjs 分别因首装缺少 capacity_error_action 而按预期失败; reviewer-fix 2026-07-14 gateway E2E failed with Retry-After deadline client timeout/no response and pre-progress buffer hard-limit injected 502; reviewer-round-2 2026-07-15 upload disconnect reproduced request_rejected+413, reordered nested config rewrote files/restarted PID, launch E2E reproduced exited-process PID-file cleanup failure
  green_evidence_ref: Task1 2026-07-14 node scripts/test-gateway-e2e.mjs => PASS codex-retry-gateway e2e; node scripts/test-install-restore.mjs => PASS install-restore flow; Task2 node scripts/test-gateway-e2e.mjs => PASS with direct-stream timing, encrypted content preservation and first-progress telemetry; Task3 node scripts/test-gateway-e2e.mjs => PASS with Capacity/429 four-action matrices, Retry-After and shared budget; Task4 node scripts/test-gateway-e2e.mjs => PASS with first-progress/total deadlines, after-forward disconnect, schema v3 metrics and JSON/CSV telemetry, plus install-restore PASS; Task5 node scripts/test-install-restore.mjs、test-launch-ui.mjs、test-launch-ui-unix.mjs => PASS，合法 none/动作/latency 配置保持字节、mtime、PID 不变，PowerShell AST 与 Node syntax 通过; reviewer-fix 2026-07-14 bundled Node gateway E2E => PASS with deadline wait single-sample 502 and strict pre-progress buffer limit; reviewer-round-2 2026-07-15 four sequential E2E PASS with bounded SSE framing, non-SSE progress, upload/Retry-After/observe-only disconnect accounting, canonical config comparison and HasExited cleanup
  reviewer_round_2_red_evidence_ref: 2026-07-15 gateway E2E failed sequentially at Capacity 429 positive Retry-After, late retry timer after total deadline, parser state exceeding 1MiB before discard, and observe-only timeout losing matched_current_rule; mislabeled SSE, mixed newline and oversized protected-event tests were present behind those RED gates
  reviewer_round_2_green_evidence_ref: 2026-07-15 Codex bundled Node four sequential E2E suites PASS with HTTP-status-based Retry-After, wall-clock deadline recheck, byte-bounded mixed-newline SSE framing, content sniffing, dedicated oversized-event 502 and preserved observe-only timeout match
  production_edit_before_red: forbidden
  test_files:
    - scripts/test-gateway-e2e.mjs
    - scripts/test-install-restore.mjs
    - scripts/test-launch-ui.mjs
    - scripts/test-launch-ui-unix.mjs
```

## Agent Lifecycle

```yaml
agent_lifecycle:
  mode: parent-implementation-bounded-final-reviewers
  max_total_agents: 2
  max_new_agents_per_round: 2
  open_agent_count_before_dispatch: 0
  reclaim_before_spawn: required
  completion_status:
    completed:
      - 019f6040-55cb-7dc0-a70d-d8a5c7a03d99 => round-2 REQUEST_CHANGES, Critical=0, Important=5
      - 019f6040-69fe-72b0-89c9-d24b9e12b6bc => round-2 REQUEST_CHANGES, Critical=0, Important=2
      - 019f622a-eb8e-7012-a0d8-363d91794436 => round-6 REQUEST_CHANGES, Critical=0, Important=1, Minor=2
      - 019f622a-ffce-7980-92b3-ef6b51ca9b73 => round-6 REQUEST_CHANGES, Critical=0, Important=2, Minor=1
    idle: []
    timeout: []
    failed: []
  closed_agent_refs:
    - 019f6040-55cb-7dc0-a70d-d8a5c7a03d99
    - 019f6040-69fe-72b0-89c9-d24b9e12b6bc
    - 019f622a-eb8e-7012-a0d8-363d91794436
    - 019f622a-ffce-7980-92b3-ef6b51ca9b73
  review_question: 可叠加策略是否在所有流式/非流式、重试预算、已写响应、配置迁移和详细采集边界下安全，且没有破坏既有高风险行为？
  closeout_rule: 两名 reviewer 正常返回最终 verdict，Critical/Important 清零并完成复审。
```

## Delivery Governance

```yaml
delivery_contract: agos.issue-pr-merge.v1
tracking_issue_ref: https://github.com/nonononull/codex-retry-gateway/issues/26
branch: codex/passthrough-retry-timeout-policies
base_dependency: PR-25-head
ci: local-verification-first-github-actions-disabled-by-repository
review: two-bounded-whole-branch-reviewers
review_strategy: two-same-question-whole-branch-reviewers-after-last-mutation
ci_expectation: repository-actions-disabled-use-fresh-local-verification
merge_policy: merge-only-after-protected-replay-two-reviewers-and-fresh-tests
pr: required
merge: owner-approved-after-verification-and-review
live_apply: forbidden
```

## External Project Warning-Mode Admission

```yaml
task_registration_status: owner-approved-external-project-warning-mode
owner_scope_ref: user:2026-07-14-approved-layered-policy-design-and-full-delivery
main_thread_confirmation: approved
tracking_issue_required: true
tracking_issue_ref: https://github.com/nonononull/codex-retry-gateway/issues/26
registration_exception_reason: 当前仓库不是 AI Growth OS 产品仓，中央 task backlog 与 business-path registry 没有该外部 Node gateway；以 GitHub issue #26、当前 session plan 和 runtime workflow 作为任务真源，不跨仓修改中央 registry。
source_edit_admission: approved-by-owner-with-project-native-plan
```

## Protected Feature Replay

```yaml
protected_feature_replay:
  required: true
  status: passed
  completion_status: passed
  baseline_ref: git:b4cac27
  known_good_features:
    - feature: reasoning-tokens-formula-and-manual-matching
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: 2026-07-15 Codex bundled Node node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
      expected_result: 518*n-2、manual values 与拦截次数保持通过
      actual_result: 518*n-2、manual values 与拦截次数保持通过
      owner_visible_status: passed
      regression_status: passed
    - feature: final-answer-only-high-xhigh-and-zero-exclusion
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: 2026-07-15 Codex bundled Node node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
      expected_result: high/xhigh、普通 0 放行与 null/非 0 语义保持通过
      actual_result: high/xhigh、普通 0 放行与 null/非 0 语义保持通过
      owner_visible_status: passed
      regression_status: passed
    - feature: context-compaction-zero-exemption
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: 2026-07-15 Codex bundled Node node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
      expected_result: 只有 context_compaction reasoning_tokens=0 豁免
      actual_result: 只有 context_compaction reasoning_tokens=0 豁免
      owner_visible_status: passed
      regression_status: passed
    - feature: continuation-recovery-folding-and-exhaustion
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: 2026-07-15 Codex bundled Node node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
      expected_result: 命中轮丢弃、最终轮折叠、共享次数与耗尽 502 保持通过
      actual_result: 命中轮丢弃、最终轮折叠、共享次数与耗尽 502 保持通过
      owner_visible_status: passed
      regression_status: passed
    - feature: capacity-legacy-retry-then-pass-through
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: 2026-07-15 Codex bundled Node node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
      expected_result: 旧 true 配置重试耗尽后仍透传原始 Capacity 响应
      actual_result: 旧 true 配置重试耗尽后仍透传原始 Capacity 响应
      owner_visible_status: passed
      regression_status: passed
    - feature: windows-and-unix-idempotent-config-recovery
      baseline_evidence_ref: git:b4cac27:scripts/test-install-restore.mjs+scripts/test-launch-ui.mjs+scripts/test-launch-ui-unix.mjs
      post_change_replay_plan_ref: node .\scripts\test-install-restore.mjs; node .\scripts\test-launch-ui.mjs; node .\scripts\test-launch-ui-unix.mjs
      post_change_replay_ref: 2026-07-15 Codex bundled Node install-restore、Windows launch、Unix launch 三组 E2E 全部 PASS
      expected_result: 合法配置复用零误写、PID 身份和恢复闭环保持通过
      actual_result: 合法配置复用零误写、PID 身份和恢复闭环保持通过
      owner_visible_status: passed
      regression_status: passed
  forbidden_ops_until_replay:
    - pr
    - merge
    - claim-done
  reject_on:
    - any protected replay failure
    - any real gateway restart or config mutation
```

## Post-Implementation Review

```yaml
post_implementation_review:
  required: true
  review_phase: after-latest-source-mutation
  review_scope: whole-source
  required_agent_count: 2
  same_question_ref: session-plan:crg-layered-gateway-policies#agent-lifecycle
  reviewer_output_refs:
    - agent:019f6040-55cb-7dc0-a70d-d8a5c7a03d99 => round-2 REQUEST_CHANGES, Critical=0, Important=5
    - agent:019f6040-69fe-72b0-89c9-d24b9e12b6bc => round-2 REQUEST_CHANGES, Critical=0, Important=2
    - agent:019f6040-55cb-7dc0-a70d-d8a5c7a03d99 => round-4 REQUEST_CHANGES, Critical=0, Important=4
    - agent:019f6040-69fe-72b0-89c9-d24b9e12b6bc => round-4 REQUEST_CHANGES, Critical=0, Important=4
    - agent:019f620a-6d9c-7e12-97da-7d7a905684e1 => round-5 PASS, Critical=0, Important=0, Minor=2
    - agent:019f620a-81e7-7783-a8c2-1a002493178d => round-5 REQUEST_CHANGES, Critical=0, Important=4, Minor=1
    - agent:019f622a-eb8e-7012-a0d8-363d91794436 => round-6 REQUEST_CHANGES, Critical=0, Important=1, Minor=2
    - agent:019f622a-ffce-7980-92b3-ef6b51ca9b73 => round-6 REQUEST_CHANGES, Critical=0, Important=2, Minor=1
  latest_rereview_findings:
    - policy retry sample closeout can delay the next real upstream dispatch beyond total deadline
    - mislabeled SSE data prefix split across chunks can be misclassified as plain-text progress
    - terminal CR-only SSE event at EOF is not flushed into rule inspection
    - disconnect mode can pass through an oversized protected SSE event after headers are sent
    - continuation, reasoning guard and first-progress retries lack the final total-deadline dispatch gate
    - pending policy samples wait for the next response headers and pollute attempt timing
    - SSE field names split inside the token and a leading UTF-8 BOM remain unhandled
    - EOF-only disconnect matches are downgraded to observe-only
    - a fetch failure after an inspected retry attempt breaks the attempt-count identity
    - mislabeled oversized first SSE event is discarded before candidate confirmation
    - standalone BOM and fallback-plus-trailing-candidate corrupt first-progress classification
    - delayed timer callbacks can lose first-progress and total hard deadlines on completion paths
    - oversized-candidate regression used an earlier default output event and could pass without exercising the candidate state
    - inspection-limit handling ran after progress/first-progress timeout classification
    - lifecycle-only chunks did not independently recheck the first-progress wall clock
    - JavaScript character splitting did not cover UTF-8 BOM bytes split across chunks
    - pending policy evidence assertion did not prove the captured range excluded retry-completion logs
  reject_if_hits:
    - retry-or-502-after-downstream-forwarding
    - total-deadline-reset-across-attempts
    - retry-budget-multiplication
    - none-mode-full-stream-buffering
    - capacity-and-429-double-consumption
    - config-migration-rewrites-valid-settings
    - incomplete-attempt-telemetry
    - protected-feature-regression
  resolved_findings_pending_rereview:
    - upload disconnect is client_disconnected with actual bytes, not request_rejected 413
    - unfinished SSE event and pre-progress buffers are bounded at 1MiB
    - non-SSE non-empty chunks mark first progress
    - timeout and Retry-After disconnect preserve attempt accounting identity
    - canonical object-key comparison prevents valid config rewrite/restart
    - observe-only disconnect preserves matched_current_rule
    - exited Windows process objects use HasExited before PID cleanup
    - Capacity HTTP 429 honors Retry-After after priority classification
    - Retry-After completion rechecks total deadline against wall clock
    - byte-bounded SSE framing supports mixed LF/CR/CRLF boundaries
    - mislabeled JSON SSE remains inspectable without breaking plain-text progress
    - oversized protected SSE returns response_inspection_limit_exceeded instead of bypassing rules
    - observe-only timeout preserves matched_current_rule
    - next policy attempt has a final wall-clock gate and old retry sample closeout cannot block dispatch
    - mislabeled SSE switches to framing on field prefixes before JSON arrives
    - EOF flushes complete CR-only terminal events into usage/structure/reasoning inspection
    - protected inspection overflow disconnects after forwarding with a dedicated final action
    - all four retry types share pending dispatch, final deadline gating and bounded dispatch yielding
    - pending samples capture their own finish time and do not wait for the next response headers
    - mislabeled SSE uses bounded candidate/confirmed/plain fallback and ignores a leading UTF-8 BOM
    - EOF-only reasoning and final-only matches disconnect instead of becoming observe-only
    - fetch failures are classified per attempt even when an earlier attempt was inspected
    - oversized SSE candidates fail closed before JSON confirmation
    - BOM-only chunks and unrecognized fallback facts survive remaining-buffer changes
    - body/chunk/EOF completion paths enforce first-progress and total deadlines by wall clock
    - undispatched retry fields and old-attempt evidence ranges remain attempt-local
    - oversized candidate tests start with the only completed event and no pre-confirming output
    - inspection-limit fail-closed runs before progress and first-progress timeout handling
    - every stream chunk rechecks the first-progress wall clock before progress classification
    - UTF-8 BOM coverage splits the three encoded bytes across network chunks
    - pending policy evidence ends before the request's internal-retry completion log; cross-process wall-clock comparison alone has a bounded 50ms tolerance
  completion_status: review-fix-batch-6-full-local-verification-passed-awaiting-final-rereview
post_implementation_review_policy:
  review_phase: post-implementation
  freshness_rule: review-after-last-mutation
  same_question_ref: session-plan:crg-layered-gateway-policies#agent-lifecycle
  required_agent_count: 2
```

## Baseline Evidence

```yaml
baseline_ref: git:b4cac27
baseline_tests:
  - node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
  - node .\scripts\test-launch-ui.mjs => PASS launch-ui flow
  - node .\scripts\test-launch-ui-unix.mjs => PASS unix launch-ui flow
  - node .\scripts\test-install-restore.mjs => PASS install-restore flow
design_commit_ref: git:82d5907
implementation_commit_refs:
  - git:b1609ad
  - git:d7573f0
  - git:2644884
  - git:150241b
  - git:4480e21
  - git:da20dee
  - git:2f63d97
  - git:6a42655
  - git:92c189d
  - git:248d001
```

## Stop Gates

- 任一新测试未先出现预期 RED，不得修改对应生产行为。
- none 模式仍等待完整 SSE 时不得称为直接透传。
- 任一分支在 `res.headersSent` 后尝试 502 或内部重试时立即停止。
- 总 deadline 被 retry 重置时立即停止。
- 429 未遵守合法 Retry-After 或泛化普通 5xx 时立即停止。
- Windows/Unix 复用启动重写合法 none/latency 配置时立即停止。
- 任何测试需要访问实际 4610 gateway 时立即停止。

## Closeout

```yaml
verification_results:
  - 2026-07-15 Codex bundled Node gateway E2E => PASS codex-retry-gateway e2e
  - 2026-07-15 Codex bundled Node install-restore E2E => PASS install-restore flow
  - 2026-07-15 Codex bundled Node Windows launch E2E => PASS launch-ui flow
  - 2026-07-15 Codex bundled Node Unix launch E2E => PASS unix launch-ui flow
  - 2026-07-15 gateway/admin/four test scripts Node syntax => PASS
  - 2026-07-15 common/install/launch PowerShell AST => PASS
  - 2026-07-15 temporary gateway process audit => 0 leftovers
  - 2026-07-15 git diff --check => PASS with line-ending warnings only
  - 2026-07-15 latest gateway E2E after round-6 fixes => PASS codex-retry-gateway e2e
  - 2026-07-15 gateway E2E stability replay before evidence tightening => 5/5 PASS
  - 2026-07-15 gateway E2E stability replay after evidence tightening and 50ms cross-process clock tolerance => 3/3 PASS
review_fix_batch_3_red_evidence:
  - next attempt reached upstream at 239ms with a 220ms total deadline when synchronous retry sample closeout ran before real dispatch
  - terminal CR-only completed SSE returned 200 instead of intercepting reasoning_tokens=516
  - disconnect mode did not close the client on an oversized protected SSE event
review_fix_batch_3_green_evidence:
  - next dispatch occurs before synchronous old-attempt closeout and the same deterministic deadline injection passes
  - field-prefix SSE sniffing, EOF CR flush and disconnect inspection overflow E2E all pass
  - four sequential bundled-Node E2E suites, six JS syntax checks, three PowerShell AST checks, diff check and temporary-process audit pass
review_fix_batch_4_red_evidence:
  - split data field token was misclassified as plain-text progress
  - reasoning guard synchronous sample closeout prevented the second dispatch before the 220ms deadline
  - pending policy sample was absent while the next fetch delayed response headers
  - EOF-only disconnect match completed normally instead of closing the connection
review_fix_batch_4_green_evidence:
  - data/event/id/retry inner-token splits and reserved-prefix plain-text fallback pass
  - policy/reasoning/continuation/first-progress retries all reach upstream before the shared deadline
  - old retry sample appears with its own duration while the next fetch is still pending
  - BOM, EOF reasoning/final-only disconnect and post-policy fetch-failure count identity pass
review_fix_batch_5_red_evidence:
  - standalone BOM was accepted as first progress
  - delayed first-progress timer allowed a late stream to return 200
  - delayed total timer allowed a late non-stream body to return 200
  - reviewer code path showed mislabeled oversized candidate and fallback-plus-tail ambiguity
review_fix_batch_5_green_evidence:
  - standalone BOM, fallback-plus-tail and mislabeled oversized candidate E2E pass
  - delayed first-progress and total timer callbacks still return wall-clock 502
  - undispatched retry fields, pending sample uniqueness/finish time and evidence bounds are asserted
review_fix_batch_6_red_evidence:
  - first oversized-candidate regression still had an earlier default output event and did not exercise candidate fail-closed
  - delayed first-progress timer plus lifecycle-only chunks exposed missing per-chunk wall-clock checks
  - inspection-limit and delayed first-progress in the same chunk required an explicit priority assertion
  - strict cross-process timestamp ordering reproduced a 4ms Windows wall-clock rollback
review_fix_batch_6_green_evidence:
  - only-completed oversized candidate returns response-inspection-limit-exceeded before timeout
  - each lifecycle chunk rechecks first-progress wall clock and the first expired chunk returns 502
  - UTF-8 BOM bytes split across chunks do not count as progress
  - pending sample evidence upper bound is lower than the current internal-retry completion log sequence
  - gateway E2E passed once and then passed three consecutive stability replays after the final test correction
full_verification_status: review-fix-batch-6-full-local-verification-passed-awaiting-final-rereview
review_refs:
  - agent:019f6040-55cb-7dc0-a70d-d8a5c7a03d99
  - agent:019f6040-69fe-72b0-89c9-d24b9e12b6bc
  - agent:019f622a-eb8e-7012-a0d8-363d91794436
  - agent:019f622a-ffce-7980-92b3-ef6b51ca9b73
pr_ref: pending
merge_ref: pending
rollout_ref: pending
sibling_regression_guard: passed
```

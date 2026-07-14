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
  red_evidence_ref: pending
  green_evidence_ref: pending
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
    completed: []
    idle: []
    timeout: []
    failed: []
  closed_agent_refs: []
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
  status: planned
  completion_status: planned
  baseline_ref: git:b4cac27
  known_good_features:
    - feature: reasoning-tokens-formula-and-manual-matching
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: pending-after-source-mutation
      expected_result: 518*n-2、manual values 与拦截次数保持通过
      owner_visible_status: pending
      regression_status: pending
    - feature: final-answer-only-high-xhigh-and-zero-exclusion
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: pending-after-source-mutation
      expected_result: high/xhigh、普通 0 放行与 null/非 0 语义保持通过
      owner_visible_status: pending
      regression_status: pending
    - feature: context-compaction-zero-exemption
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: pending-after-source-mutation
      expected_result: 只有 context_compaction reasoning_tokens=0 豁免
      owner_visible_status: pending
      regression_status: pending
    - feature: continuation-recovery-folding-and-exhaustion
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: pending-after-source-mutation
      expected_result: 命中轮丢弃、最终轮折叠、共享次数与耗尽 502 保持通过
      owner_visible_status: pending
      regression_status: pending
    - feature: capacity-legacy-retry-then-pass-through
      baseline_evidence_ref: git:b4cac27:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      post_change_replay_ref: pending-after-source-mutation
      expected_result: 旧 true 配置重试耗尽后仍透传原始 Capacity 响应
      owner_visible_status: pending
      regression_status: pending
    - feature: windows-and-unix-idempotent-config-recovery
      baseline_evidence_ref: git:b4cac27:scripts/test-install-restore.mjs+scripts/test-launch-ui.mjs+scripts/test-launch-ui-unix.mjs
      post_change_replay_plan_ref: node .\scripts\test-install-restore.mjs; node .\scripts\test-launch-ui.mjs; node .\scripts\test-launch-ui-unix.mjs
      post_change_replay_ref: pending-after-source-mutation
      expected_result: 合法配置复用零误写、PID 身份和恢复闭环保持通过
      owner_visible_status: pending
      regression_status: pending
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
  reviewer_output_refs: []
  reject_if_hits:
    - retry-or-502-after-downstream-forwarding
    - total-deadline-reset-across-attempts
    - retry-budget-multiplication
    - none-mode-full-stream-buffering
    - capacity-and-429-double-consumption
    - config-migration-rewrites-valid-settings
    - incomplete-attempt-telemetry
    - protected-feature-regression
  completion_status: planned
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
verification_results: []
review_refs: []
pr_ref: pending
merge_ref: pending
rollout_ref: pending
sibling_regression_guard: pending
```

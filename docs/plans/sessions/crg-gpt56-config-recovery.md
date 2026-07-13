# Session Plan

```yaml
schema_version: agos.session-plan.v1
architecture_contract_version: agos.brainstorming-gate.v1
task_id: crg-gpt56-config-recovery
work_class: standard
task_summary: 更新 GPT-5.6 模型与 reasoning effort 观测，并把 gateway 接管恢复改成先检测、按需修复的幂等流程。
project_root: C:\Users\dashuai\Documents\Playground\codex-retry-gateway-gpt56
trigger_source: user-approved-plan-and-start-2026-07-13
decision_status: approved
approval_source: inherited-user-instruction
approved_decision_ref: session-plan:crg-gpt56-config-recovery#decision
scope_hash: crg-gpt56-model-effort-idempotent-recovery-v1
mutation_intent: source
allowed_operations:
  - read
  - edit
  - test
  - local-review
executor_enforcement: tdd-local-verification-no-live-gateway-restart
selected_business_path: external-project-node-gateway-development
session_plan_ref: docs/plans/sessions/crg-gpt56-config-recovery.md
runtime_workflow_ref: .ai-growth-os/runtime-workflows/crg-gpt56-config-recovery.yml
implementation_plan_ref: docs/plans/2026-07-13-gpt56-config-recovery-implementation.md
```

## Approved Decision

- 识别 `gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna`，统计时保留各自家族键，不把三个模型折叠成一个不可区分的 `gpt-5.6`。
- reasoning 行为采集接受 `minimal / low / medium / high / xhigh / max / ultra`；本轮只扩展观测与探针参数校验，不改变 `final_answer_only_high_xhigh` 的既有拦截语义。
- `518*n-2` 仍是模型无关规则，因此 GPT-5.6 的 `516` 沿用现有命中、内部重试或续写链路，不新增模型特判。
- 启动入口先判断 Codex provider、gateway 配置迁移需求和运行进程。已正确接管且进程存活时不重写文件、不重启；配置缺失/漂移或进程停止时才执行对应修复。
- Windows PowerShell 与 macOS/Linux Node 管理核心保持同一语义；不触碰当前实际运行中的本地 gateway。

## Assumptions And Uncertainty

- 本机 Codex 当前配置实证为 `model=gpt-5.6-terra`、`model_reasoning_effort=xhigh`。
- 当前会话能力清单实证：`sol/terra` 支持 `low/medium/high/xhigh/max/ultra`，`luna` 支持到 `max`；官方 Codex 手册端点本机访问返回 HTTP 403，因此不把不可访问页面当作额外证据。
- gateway 是被动观测层，不应按模型能力矩阵丢弃收到的 `max/ultra`；上游若发来这些值，应完整落盘。
- “恢复配置”按上下文解释为一键启动时恢复 gateway 接管，而不是“恢复 Codex 原设置”按钮。

## Local Knowledge Lookup

```yaml
local_knowledge_lookup:
  gbrain_queries:
    - "codex retry gateway 模型 家族 reasoning effort 恢复配置 幂等"
  gbrain_result: no-results
  vault_refs:
    - D:\Android_source\ai-growth-os\components\rules\rules\workflows\ai-growth-os-auto-application.md
    - D:\Android_source\ai-growth-os\components\rules\rules\workflows\ai-growth-os-brainstorming-gate.md
    - D:\Android_source\ai-growth-os\components\rules\rules\workflows\ai-growth-os-runtime-workflow.md
  rules_refs:
    - D:\Android_source\ai-growth-os\components\rules\rules\domain\agent-generated-code.md
    - D:\Android_source\ai-growth-os\components\rules\rules\quality\testing.md
  project_refs:
    - README.md
    - build.md
    - err.md
    - gateway.mjs
    - scripts/admin-lib.mjs
    - scripts/launch-ui.ps1
    - scripts/test-gateway-e2e.mjs
    - scripts/test-launch-ui.mjs
    - scripts/test-launch-ui-unix.mjs
  missing_coverage:
    - 本地脑库没有该项目的 GPT-5.6/幂等恢复现成结论，项目源码、当前 Codex 配置与回归测试作为本轮事实源。
```

## Change Contract

```yaml
change_contract:
  target_contract: GPT-5.6 请求按真实模型和 effort 进入统计；启动入口仅在接管或运行状态需要修复时产生写入/重启。
  preserved_invariants:
    - 518*n-2 规则与 516 命中语义不变
    - final_answer_only_high_xhigh 仅 high/xhigh 的实验语义不变
    - 用户已有 gateway 配置项和原始 upstream 不被覆盖
    - restore-codex-config 仍能恢复首次安装前配置
    - Windows 与 Unix 入口均可首次安装、迁移旧配置并拉起停止的 gateway
  adjacent_surfaces:
    - 模型一致性 family_breakdown
    - 主动探针 target_families
    - reasoning analytics 分桶和分析筛选
    - install/restore 备份链
    - launch-ui 进程生命周期
  historical_state_refs:
    - state.json 可能仍声称已接管，但 Codex provider 已绕过 gateway
    - config.json 可能缺少后来新增字段
  stale_verdict_invalidation_refs:
    - 旧 README 中“之后每次启动都会重启 gateway”的描述
  regression_checks:
    - node .\scripts\test-gateway-e2e.mjs
    - node .\scripts\test-launch-ui.mjs
    - node .\scripts\test-launch-ui-unix.mjs
    - node .\scripts\test-install-restore.mjs
    - node --check .\gateway.mjs
    - node --check .\scripts\admin-lib.mjs
  sibling_regression_guard: pending
```

## Agent Lifecycle

```yaml
proposal_mode: delegated-agents
superpowers_skill: superpowers:brainstorming
actual_agent_count: 2
agent_lifecycle:
  budget:
    max_total_agents: 2
    max_new_agents_per_round: 2
    actual_agent_count: 2
  spawn_preconditions:
    dispatch_plan_ref: docs/plans/sessions/crg-gpt56-config-recovery-dispatch.yml
    reclaim_before_spawn: not-needed-zero-open
    open_agent_count_before_dispatch: 0
  completion_status:
    completed: []
    idle: []
    timeout: []
    failed: []
  closed_agent_refs: []
  closeout_rule: all-completed-idle-timeout-agents-closed-or-owner-exception
```

## Delivery Governance

```yaml
delivery_mode: local-implementation-no-live-apply
tracking: not-requested
branch: codex/gpt56-integration-state
review: bounded-agent-review-plus-local-tests
ci: local-verification-only
merge: not-in-current-scope
```

## External Project Warning-Mode Admission

```yaml
task_registration_status: owner-approved-external-project-warning-mode
owner_scope_ref: user:2026-07-13-ui-owned-by-codex-start-implementation
main_thread_confirmation: approved
tracking_issue_required: false
registration_exception_reason: 当前仅做本地实现与验证，用户尚未要求 GitHub issue/PR/merge；不修改 AI Growth OS registry。
source_edit_admission: approved-by-owner-with-project-native-plan
```

## Protected Feature Replay

```yaml
protected_feature_replay:
  required: true
  baseline_ref: git:827c918
  completion_status: planned
  protected_features:
    - feature: reasoning-tokens-formula-and-516-interception
      baseline_evidence: scripts/test-gateway-e2e.mjs existing formula/manual/516 cases
      replay_command: node .\scripts\test-gateway-e2e.mjs
    - feature: final-answer-only-high-xhigh-and-zero-exemption
      baseline_evidence: scripts/test-gateway-e2e.mjs existing final-only and compaction cases
      replay_command: node .\scripts\test-gateway-e2e.mjs
    - feature: continuation-recovery-folding-and-retry-limit
      baseline_evidence: PR 23 merged at git:827c918
      replay_command: node .\scripts\test-gateway-e2e.mjs
    - feature: install-backup-and-restore-original-config
      baseline_evidence: scripts/test-install-restore.mjs and scripts/test-launch-ui*.mjs
      replay_command: node .\scripts\test-install-restore.mjs
    - feature: windows-and-unix-first-launch
      baseline_evidence: scripts/test-launch-ui.mjs and scripts/test-launch-ui-unix.mjs
      replay_command: node .\scripts\test-launch-ui.mjs; node .\scripts\test-launch-ui-unix.mjs
  reject_on:
    - any protected replay failure
    - any real gateway restart during tests
```

## Post-Implementation Review

```yaml
post_implementation_review:
  required: true
  same_question: GPT-5.6 观测与幂等恢复是否完整且未改变既有拦截、续写、备份和恢复语义
  review_plan:
    - model-contract-reviewer
    - recovery-idempotency-reviewer
  completion_status: pending
  verify_command: verify-post-implementation-review.ps1 -Path docs/plans/sessions/crg-gpt56-config-recovery.md -ReportOnly
```

## Closeout

```yaml
verification_results: []
review_refs: []
rollout_ref: pending
sibling_regression_guard: pending
```

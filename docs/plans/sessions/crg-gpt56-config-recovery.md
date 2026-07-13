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
  - commit
  - push
  - pr
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
  sibling_regression_guard: passed
```

## Agent Lifecycle

```yaml
proposal_mode: delegated-agents-timeout-then-fresh-bounded-review
superpowers_skill: superpowers:brainstorming
actual_agent_count: 6
agent_lifecycle:
  budget:
    max_total_agents: 6
    max_new_agents_per_round: 2
    actual_agent_count: 6
  spawn_preconditions:
    dispatch_plan_ref: docs/plans/sessions/crg-gpt56-config-recovery-dispatch.yml
    reclaim_before_spawn: not-needed-zero-open
    open_agent_count_before_dispatch: 0
  completion_status:
    completed:
      - 019f5b25-b934-7d60-8473-7b6d12f31efa
      - 019f5b25-cd52-7b13-8028-c4b53539d99c
    idle: []
    timeout:
      - 019f5ad8-cbcb-7070-940a-ff8c8ce73006
      - 019f5ad8-dfda-7031-9306-75da4cb71b0f
      - 019f5ae8-28d2-7953-9d14-29883d90e2e5
      - 019f5ae8-3d0c-71e1-a881-6fdaac802d03
    failed: []
  closed_agent_refs:
    - 019f5ad8-cbcb-7070-940a-ff8c8ce73006
    - 019f5ad8-dfda-7031-9306-75da4cb71b0f
    - 019f5ae8-28d2-7953-9d14-29883d90e2e5
    - 019f5ae8-3d0c-71e1-a881-6fdaac802d03
    - 019f5b25-b934-7d60-8473-7b6d12f31efa
    - 019f5b25-cd52-7b13-8028-c4b53539d99c
  timeout_handling: four-timeouts-closed-then-two-fresh-reviewers-completed-with-final-ready-verdicts
  closeout_rule: all-completed-idle-timeout-agents-closed-or-owner-exception
```

## Delivery Governance

```yaml
delivery_mode: local-verification-then-pr-no-live-apply
tracking: https://github.com/nonononull/codex-retry-gateway/issues/24
branch: codex/gpt56-integration-state
review: two-completed-bounded-reviewers-plus-local-tests
ci: local-verification-only
merge: not-in-current-scope
```

## External Project Warning-Mode Admission

```yaml
task_registration_status: owner-approved-external-project-warning-mode
owner_scope_ref: user:2026-07-13-ui-owned-by-codex-start-implementation
main_thread_confirmation: approved
tracking_issue_required: true
tracking_issue_ref: https://github.com/nonononull/codex-retry-gateway/issues/24
registration_exception_reason: 用户已要求提交并创建 PR；已在 PR 前补 GitHub tracking issue，不修改 AI Growth OS registry。
source_edit_admission: approved-by-owner-with-project-native-plan
```

## Protected Feature Replay

```yaml
protected_feature_replay:
  required: true
  status: passed
  baseline_ref: git:827c918
  known_good_features:
    - feature: reasoning-tokens-formula-and-516-interception
      baseline_evidence_ref: git:827c918:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      expected_result: PASS codex-retry-gateway e2e
      post_change_replay_ref: local:2026-07-13:test-gateway-e2e
      actual_result: PASS codex-retry-gateway e2e
      owner_visible_status: passed
      regression_status: passed
    - feature: final-answer-only-high-xhigh-and-zero-exemption
      baseline_evidence_ref: git:827c918:scripts/test-gateway-e2e.mjs
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      expected_result: PASS codex-retry-gateway e2e
      post_change_replay_ref: local:2026-07-13:test-gateway-e2e
      actual_result: PASS codex-retry-gateway e2e
      owner_visible_status: passed
      regression_status: passed
    - feature: continuation-recovery-folding-and-retry-limit
      baseline_evidence_ref: PR-23@git:827c918
      post_change_replay_plan_ref: node .\scripts\test-gateway-e2e.mjs
      expected_result: PASS codex-retry-gateway e2e
      post_change_replay_ref: local:2026-07-13:test-gateway-e2e
      actual_result: PASS codex-retry-gateway e2e
      owner_visible_status: passed
      regression_status: passed
    - feature: install-backup-and-restore-original-config
      baseline_evidence_ref: git:827c918:scripts/test-install-restore.mjs
      post_change_replay_plan_ref: node .\scripts\test-install-restore.mjs
      expected_result: PASS install-restore flow
      post_change_replay_ref: local:2026-07-13:test-install-restore
      actual_result: PASS install-restore flow
      owner_visible_status: passed
      regression_status: passed
    - feature: windows-and-unix-first-launch
      baseline_evidence_ref: git:827c918:scripts/test-launch-ui.mjs+scripts/test-launch-ui-unix.mjs
      post_change_replay_plan_ref: node .\scripts\test-launch-ui.mjs; node .\scripts\test-launch-ui-unix.mjs
      expected_result: PASS launch-ui flow and PASS unix launch-ui flow
      post_change_replay_ref: local:2026-07-13:test-launch-ui-windows-and-unix
      actual_result: PASS launch-ui flow and PASS unix launch-ui flow
      owner_visible_status: passed
      regression_status: passed
```

## Post-Implementation Review

```yaml
post_implementation_review:
  required: true
  review_phase: post-implementation
  same_question_ref: session-plan:crg-gpt56-config-recovery#same-question-review
  review_scope: whole-source
  owner_requested_scope: whole-source
  baseline_snapshot_ref: git:827c918
  implementation_snapshot_ref: worktree:codex/gpt56-integration-state
  last_mutation_ref: worktree:failed-start-pid-write-cleanup-final
  review_after_last_mutation: true
  changed_files_ref: git-diff:origin/main
  reviewer_input_bundle_ref: docs/plans/sessions/crg-gpt56-config-recovery.md
  required_agent_count: 2
  returned_agent_count: 2
  reviewer_output_refs:
    - agent:019f5b25-b934-7d60-8473-7b6d12f31efa#completed-ready-to-merge-yes
    - agent:019f5b25-cd52-7b13-8028-c4b53539d99c#completed-ready-to-merge-yes
  reject_if_hits: []
  parent_review:
    review_status: completed-with-fixes
    findings_fixed:
      - active-probe-effort-cross-model-overflow
      - missing-config-fake-recovery-backup
      - mismatched-provider-original-upstream-reuse
      - unix-backup-path-not-a-file
      - gpt56-prefix-boundary-and-effort-matrix-gaps
      - stale-live-pid-process-termination
      - cross-provider-recovery-backup-reuse
      - directory-recovery-point-stop-before-validation
      - missing-config-failed-migration-rollback
      - direct-install-control-plane-divergence
      - direct-start-stale-pid-trust
      - missing-config-stop-restore-orphan-process
      - health-success-not-bound-to-child-pid
      - failed-start-child-cleanup-gap
      - pid-write-failure-outside-cleanup-boundary
  parent_resolution:
    status: ready
    implementation_freeze_status: released
    allowed_ops:
      - local-verification
      - commit
      - push
      - pr
    forbidden_ops:
      - merge
      - live-apply
      - claim-merged
  completion_status: passed
  verify_command: verify-post-implementation-review.ps1 -Path docs/plans/sessions/crg-gpt56-config-recovery.md -ReportOnly
```

## Closeout

```yaml
verification_results:
  - node .\scripts\test-launch-ui.mjs => PASS launch-ui flow
  - node .\scripts\test-launch-ui-unix.mjs => PASS unix launch-ui flow
  - node .\scripts\test-gateway-e2e.mjs => PASS codex-retry-gateway e2e
  - node --check .\gateway.mjs => exit 0
  - node --check .\scripts\admin-lib.mjs => exit 0
  - PowerShell AST parse common/install/launch/restore/start/stop => PASS (6 files)
  - git diff --check => exit 0
  - temporary gateway process audit => PASS no temporary gateway process remains
prior_verification_results:
  - node .\scripts\test-install-restore.mjs => PASS install-restore flow before the final start-process cleanup changes
final_rerun_limitations:
  - node .\scripts\test-install-restore.mjs => 未进入测试；权限审批服务返回 GitHub 上游 503 并明确禁止绕过。后续 start 相关变更由最终 Windows/Unix launch E2E 覆盖，不把该项记为最终 revision 的 fresh PASS。
review_refs:
  - parent-review:completed-with-four-fixes
  - multi-agent-round-1:two-timeouts-closed
  - multi-agent-round-2:two-timeouts-closed
  - reviewer-a:019f5b25-b934-7d60-8473-7b6d12f31efa:completed-ready-to-merge-yes
  - reviewer-b:019f5b25-cd52-7b13-8028-c4b53539d99c:completed-ready-to-merge-yes-after-findings-fixed
governance_results:
  - protected-feature-replay => ready/passed (5/5)
  - test-governance-matrix => ready
  - post-implementation-review => ready/two-completed-reviewers
rollout_ref: workflow-rollout-repair-required-missing-formal-source-task
rollout_note: record-workflow-rollout.ps1 dry-run 返回 WORKFLOW_ROLLOUT_REPAIR_REQUIRED；本任务按 external-project warning-mode 未登记 AI Growth OS 正式 source task，也未修改 registry。
sibling_regression_guard: passed
```

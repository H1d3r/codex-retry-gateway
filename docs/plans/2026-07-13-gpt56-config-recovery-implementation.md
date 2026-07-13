# GPT-5.6 与配置恢复实现计划

> **执行要求：** 按 TDD 逐项推进；每个生产改动必须先看到对应测试按预期失败。当前实际运行 gateway 不在本计划内重启。

**目标：** 完整区分 GPT-5.6 模型与新增思考等级，并让重复启动成为真正无写入、无重启的幂等操作。

**架构：** 模型兼容集中在 `gateway.mjs` 的规范化集合与 UI 默认筛选；接管恢复分别在 PowerShell 入口和跨平台 `admin-lib.mjs` 中计算“配置是否变化、provider 是否漂移、进程是否存活”，按差异执行最小动作。

**技术栈：** Node.js 18+、PowerShell 5.1+、Bash、内置 E2E 脚本。

## 全局约束

- 不更改现有路由、516 公式、重试次数、续写或拦截语义。
- 不把 5.6 三个模型折叠为同一统计键。
- 不重启当前 `127.0.0.1:4610` 实际 gateway。
- 只修改与本请求直接相关的源码、测试和文档。

### 任务 1：锁定 GPT-5.6 观测契约

**文件：** `scripts/test-gateway-e2e.mjs`、`gateway.mjs`

- [ ] 增加 `gpt-5.6-sol/terra/luna` 与 `max/ultra` 请求样本，断言 reasoning analytics、family breakdown 和主动探针保留正确值。
- [ ] 运行 `node .\scripts\test-gateway-e2e.mjs`，确认新增断言因 5.6/effort 未支持而失败。
- [ ] 扩展模型家族和 effort 规范化；UI 分析条件默认值加入 `max,ultra`。
- [ ] 重跑 E2E，确认 516 仍按原规则命中且新增观测断言通过。

### 任务 2：锁定幂等接管契约

**文件：** `scripts/test-launch-ui.mjs`、`scripts/test-launch-ui-unix.mjs`、`scripts/test-install-restore.mjs`

- [ ] 在 Windows 与 Unix 启动测试中记录第一次启动后的 PID、Codex 配置、gateway 配置、state 和备份列表。
- [ ] 第二次启动断言 PID 不变，三个配置文件内容与备份数量不变。
- [ ] 增加 gateway 已停止时只拉起进程、provider 漂移时才恢复接管的用例。
- [ ] 运行三个测试脚本，确认旧实现因无条件写入/重启而失败。

### 任务 3：实现按需恢复

**文件：** `scripts/admin-lib.mjs`、`scripts/launch-ui.ps1`

- [ ] 把 reuse 配置迁移结果先在内存计算，并与磁盘值比较。
- [ ] 仅配置变化时写 `config.json`；仅 provider 漂移时改 `config.toml`。
- [ ] gateway 存活且配置未变化时不重启；停止时拉起；配置变化时才重启加载新配置。
- [ ] 仅状态字段确有变化时写 `state.json`，无动作重复启动保持文件内容不变。
- [ ] 重跑 Windows、Unix、安装恢复测试直至通过。

### 任务 4：文档与全量验证

**文件：** `README.md`、`build.md`、`err.md`、本 session plan/runtime workflow

- [ ] 记录 GPT-5.6、effort、516 模型无关规则和幂等启动语义。
- [ ] 在 `err.md` 记录“安装状态与当前 provider 实际接管状态分离”的根因与防回归检查。
- [ ] 运行全部四个测试脚本、两个 `node --check`、`git diff --check`。
- [ ] 更新 session plan/runtime workflow 的验证、评审与 sibling regression guard 结果。

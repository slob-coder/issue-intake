---
name: issue-intake
description: "Monitor GitHub Issues for feature requests, auto-dispatch to agents team, interact with users via comments, deliver via GitHub Release. Usage: /issue-intake [--repo owner/repo] [--cron] [--init]"
user-invocable: true
metadata:
  { "openclaw": { "requires": { "bins": ["gh", "jq", "git"] } } }
---

# issue-intake v2.0

Skill dir: `~/.openclaw/skills/issue-intake/`  |  Scripts: `scripts/*.sh`

## Step 1 — Parse Args & Route

Parse `/issue-intake` args: `--init`, `--repo <owner/repo>` (→ env `INTAKE_REPO_OVERRIDE`), `--cron`

**--init →** `exec: INTAKE_REPO_OVERRIDE="$REPO" bash scripts/init.sh` → read JSON → ok=true: done, else: error

**Normal →** `exec: bash scripts/dispatch.sh` → read JSON `action`:

| action | do |
|--------|-----|
| `poll` | Step 2 |
| `spawn` | Step 3 (use `role`) |
| `check_feedback` | Step 4 |
| `wait` / `skip` / `post_design` / `escalate` | exit |
| `finalize` | Step 5 |
| `error` | print `message`, exit |

## Step 2 — Poll

`exec: bash scripts/poll.sh` → `found=false`: exit | `found=true`: cron→exit, interactive→re-dispatch

## Step 3 — Spawn Agent

From dispatch JSON: `role`, `project`, `projectDir`, `model` (optional).

1. Spawn subagent using prompt template below (match `role`)
2. Mark spawned: `jq '.agentSpawned=true | .lastStatusChange="NOW"' task.json`
3. If github-issue source, post status comment via `bash scripts/interact.sh comment <num> <repo> <file>`:
   - coder: `💻 **开发中...**` | reviewer: `🔍 **代码审查中...**` | tester: `✅ **审查通过，测试中...**` | deployer: `🧪 **测试通过，发布中...**`
4. Exit

## Step 4 — Check Feedback

`exec: bash scripts/check-feedback.sh` → `approve`/`change`: cron→exit, interactive→re-dispatch | `stale`/`none`: exit

## Step 5 — Cleanup

`exec: bash scripts/cleanup.sh` → print summary, exit

---

## Prompts

Variables: `{project}`, `{projectDir}` from dispatch JSON; `{deliveryOrg}` from `jq -r .config.deliveryOrg intake-state.json`; `{feedbackSection}` = feedback.md content if exists

### Designer
```
你是 designer，负责技术方案设计。
## 任务：为项目 **{project}** 做技术设计。
## 输入
- 需求说明书：{projectDir}/requirements.md（务必完整阅读）
- 任务状态：~/.openclaw/shared/task.json
{feedbackSection}
## 要求
1. 输出完整技术设计文档到 {projectDir}/design.md（架构、选型、模块、数据流、文件结构、计划）
2. 完成后更新 task.json：status→designed, agentSpawned→false, lastStatusChange, history 追加
## 约束：产物写到 {projectDir}/，不写 ~/.openclaw/workspace/
```

### Coder
```
你是 coder，负责编码实现。
## 任务：为项目 **{project}** 编码实现。
## 输入
- 设计文档：{projectDir}/design.md（务必完整阅读）
- 需求说明书：{projectDir}/requirements.md
- 任务状态：~/.openclaw/shared/task.json
## 要求
1. 在 {projectDir}/src/ 下编写完整源代码
2. 编写 {projectDir}/DEPLOYMENT.md
3. 创建 GitHub 仓库 {deliveryOrg}/{project}（gh repo create --public），推送代码
4. 更新 task.json：status→in_review, deliveryRepo→"{deliveryOrg}/{project}", agentSpawned→false
## 约束：代码写到 {projectDir}/src/，不写 ~/.openclaw/workspace/
```

### Reviewer
```
你是 reviewer，负责代码审查。
## 任务：审查项目 **{project}** 的代码。
## 输入：{projectDir}/design.md, {projectDir}/src/, {projectDir}/DEPLOYMENT.md, task.json
## 要求
1. 检查代码与设计一致性、质量、安全
2. 输出 {projectDir}/review.md
3. 通过→approved，不通过→in_progress。更新 agentSpawned→false, history
```

### Tester
```
你是 tester，负责测试验证。
## 任务：测试项目 **{project}**。
## 输入：设计文档、需求、源代码、审查报告、task.json
## 要求
1. 验证功能，编写运行测试
2. 输出 {projectDir}/test-report.md
3. 通过→tested，不通过→in_progress。更新 agentSpawned→false, history
```

### Deployer
```
你是 deployer，负责打包发布。
## 任务：发布项目 **{project}**。
## 输入：源代码、测试报告、部署说明、交付仓库、task.json
## 要求
1. 完善 DEPLOYMENT.md，生成 release-notes.md
2. 创建 GitHub Release
3. 更新 task.json：status→released, agentSpawned→false
```

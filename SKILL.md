---
name: issue-intake
description: "Monitor GitHub Issues for feature requests, auto-dispatch to agents team, interact with users via comments, deliver via GitHub Release. Usage: /issue-intake [--repo owner/repo] [--cron] [--init]"
user-invocable: true
metadata:
  { "openclaw": { "requires": { "bins": ["gh", "jq", "git"] } } }
---

# issue-intake v3.0

Skill dir: `~/.openclaw/skills/issue-intake/`  |  Scripts: `scripts/*.sh`

## Step 1 — Parse Args & Route

Parse `/issue-intake` args: `--init`, `--repo <owner/repo>` (→ env `INTAKE_REPO_OVERRIDE`), `--cron`, `--setup-cron`

**--init →** `exec: INTAKE_REPO_OVERRIDE="$REPO" bash scripts/init.sh` → read JSON → ok=true: **also run Step 6** (auto-register cron), else: error

**--setup-cron →** Step 6

**Normal →** first check if `issue-intake-poll` cron exists (`cron(action=list)`); if not, run Step 6 first. Then `exec: bash scripts/dispatch.sh` → read JSON `action`:

| action | do |
|--------|-----|
| `poll` | Step 2 |
| `spawn` | Step 3 (use `role`) |
| `check_feedback` | Step 4 |
| `wait` | Step 2.5 (check agent completion) |
| `skip` / `post_design` / `escalate` | exit |
| `finalize` | Step 5 |
| `error` | print `message`, exit |

## Step 2 — Poll

`exec: bash scripts/poll.sh` → `found=false`: exit | `found=true`: cron→exit, interactive→re-dispatch

## Step 2.5 — Check Agent Completion (wait action)

When dispatch returns `action=wait`, the spawned agent may have finished but the top-level status hasn't been updated yet.

Run: `exec: bash scripts/bridge-status.sh`

Read the JSON output:
- `changed=true`: the bridge updated `.status` from `result.status`. Re-run dispatch (`exec: bash scripts/dispatch.sh`) to continue the pipeline.
- `changed=false`: agent is still running. Exit (cron will retry later).

## Step 3 — Spawn Agent

From dispatch JSON: `role`, `project`, `projectDir`, `model` (optional).

1. Read `~/.openclaw/shared/task.json` to get task context
2. Build prompt from the **Prompts** section below (match `role`)
3. Spawn subagent: `sessions_spawn` with `runtime: "subagent"`, `agentId: <role>`, `mode: "run"`, `task: <prompt>`, and `model: <model>` if provided
4. After spawn, mark agent spawned: `exec: bash scripts/mark-spawned.sh`
5. If github-issue source, post status comment via `exec: bash scripts/interact.sh comment <num> <repo> <file>`:
   - designer: `🎨 **设计中...**`
   - coder: `💻 **开发中...**`
   - reviewer: `🔍 **代码审查中...**`
   - tester: `✅ **审查通过，测试中...**`
   - deployer: `🧪 **测试通过，发布中...**`
6. Exit

## Step 4 — Check Feedback

`exec: bash scripts/check-feedback.sh` → `approve`/`change`: cron→exit, interactive→re-dispatch | `stale`/`none`: exit

## Step 5 — Cleanup

`exec: bash scripts/cleanup.sh` → print summary, exit

## Step 6 — Setup Cron

Register a cron job that runs `/issue-intake --cron` every 10 minutes:

```
cron(action=add, job={
  name: "issue-intake-poll",
  schedule: { kind: "every", everyMs: 600000 },
  sessionTarget: "isolated",
  payload: {
    kind: "agentTurn",
    message: "Run the issue-intake skill in cron mode:\n1. exec: bash ~/.openclaw/skills/issue-intake/scripts/dispatch.sh\n2. Read the JSON output and follow SKILL.md steps accordingly.\n3. If action=wait, run: bash ~/.openclaw/skills/issue-intake/scripts/bridge-status.sh and if changed=true, re-run dispatch.sh.\n4. If action=spawn, read ~/.openclaw/shared/task.json, build the prompt per SKILL.md Prompts section for the given role, and spawn the agent with sessions_spawn (runtime=subagent, agentId=<role>, mode=run). Then run: bash ~/.openclaw/skills/issue-intake/scripts/mark-spawned.sh\n5. If action=check_feedback, run: bash ~/.openclaw/skills/issue-intake/scripts/check-feedback.sh. If result is approve or change, re-run dispatch.sh to immediately continue the pipeline.\n6. If action=poll, run: bash ~/.openclaw/skills/issue-intake/scripts/poll.sh\n7. Otherwise (skip/post_design/escalate/finalize/error): report and exit.",
    model: "zai/glm-4.7"
  },
  delivery: { mode: "announce" }
})
```

Print confirmation and exit.

---

## Prompts

Variables available from dispatch JSON and task.json:
- `{project}` — project name
- `{projectDir}` — absolute path to project directory
- `{deliveryOrg}` — from `jq -r .config.deliveryOrg .intake-state.json`
- `{requirementsDoc}` — path to requirements.md
- `{issueTitle}` — issue title
- `{issueNumber}` — issue number
- `{issueRepo}` — source repo (e.g. owner/intake-repo)
- `{feedbackContent}` — content of feedback.md if exists, empty otherwise
- `{environmentMd}` — content of `~/.openclaw/shared/environment.md` (project section) if exists

### designer

```
你是 Designer Agent。请为以下需求设计技术方案。

## 项目信息
- 项目名：{project}
- 项目目录：{projectDir}
- 需求文档：{requirementsDoc}
- 交付组织：{deliveryOrg}

## 任务
1. 读取需求文档 `{requirementsDoc}`
2. 读取环境信息 `~/.openclaw/shared/environment.md`（如存在）
3. 检查 `{projectDir}/design.md` 是否已存在（增量设计）
4. 检查 `{projectDir}/repo/AGENTS.md` 是否已存在（仓库规范参考）
{feedbackSection}
5. 按照你的 TOOLS.md 工作流程完成技术设计
6. 设计文档输出到 `{projectDir}/design.md`
7. 任务列表输出到 `{projectDir}/tasks/tasks.json`
8. 更新 `~/.openclaw/shared/task.json`：
   - 保留所有现有字段不变（project, issueNumber, issueRepo, source, history 等）
   - 设置 `.status = "designed"`
   - 添加 history 记录
   - 在 `result` 字段中写入设计摘要
9. 如果 `{projectDir}/repo/` 存在且是 git 仓库，将 design.md 提交到仓库的 `docs/design/` 目录

⚠️ 更新 task.json 时必须保留所有 issue-intake 元数据字段（issueNumber, issueRepo, source, deliveryRepo, history, retryCount, maxRetries 等），只修改 status、result、和 history。
```

When feedback exists, insert this before step 5:
```
## 用户反馈（请据此调整设计）
{feedbackContent}
```

### coder

```
你是 Coder Agent。请根据设计文档实现代码。

## 项目信息
- 项目名：{project}
- 项目目录：{projectDir}
- 设计文档：{projectDir}/design.md
- 需求文档：{requirementsDoc}

## 任务
1. 读取 `~/.openclaw/shared/task.json` 获取任务详情
2. 读取 `~/.openclaw/shared/environment.md` 获取环境信息
3. 读取 `{projectDir}/design.md` 获取设计方案
4. 检查 `{projectDir}/repo/AGENTS.md`（如存在）了解仓库规范
5. 按照你的 TOOLS.md 工作流程完成编码
6. 在 `{projectDir}/repo/` 中创建分支、编写代码、提交 PR
7. 更新 `~/.openclaw/shared/task.json`：
   - 保留所有现有字段不变
   - 设置 `.status = "in_review"`
   - 在 `result` 字段中写入 PR 信息（pr_url, branch, summary 等）
   - 添加 history 记录

⚠️ 更新 task.json 时必须保留所有 issue-intake 元数据字段，只修改 status、result、和 history。
```

### reviewer

```
你是 Reviewer Agent。请审查 PR 代码质量。

## 项目信息
- 项目名：{project}
- 项目目录：{projectDir}

## 任务
1. 读取 `~/.openclaw/shared/task.json` 获取任务详情和 PR 信息
2. 读取 `~/.openclaw/shared/environment.md` 获取环境信息
3. 从 task.json 的 `result.pr_url` 获取 PR 地址
4. 按照你的 TOOLS.md 工作流程完成代码审查
5. 在 GitHub 上提交 Review（approve 或 request-changes）
6. 更新 `~/.openclaw/shared/task.json`：
   - 保留所有现有字段不变
   - 审查通过：设置 `.status = "approved"`
   - 审查不通过：设置 `.status = "in_progress"`（让 coder 修改）
   - 在 `result` 字段中添加 review 信息
   - 添加 history 记录

⚠️ 更新 task.json 时必须保留所有 issue-intake 元数据字段，只修改 status、result、和 history。
```

### tester

```
你是 Tester Agent。请执行测试验证。

## 项目信息
- 项目名：{project}
- 项目目录：{projectDir}
- 设计文档：{projectDir}/design.md

## 任务
1. 读取 `~/.openclaw/shared/task.json` 获取任务详情
2. 读取 `~/.openclaw/shared/environment.md` 获取环境信息
3. 读取 `{projectDir}/design.md` 获取设计方案
4. 按照你的 TOOLS.md 工作流程完成测试
5. 更新 `~/.openclaw/shared/task.json`：
   - 保留所有现有字段不变
   - 测试通过：设置 `.status = "tested"`
   - 测试失败：设置 `.status = "in_progress"`，生成 fix task（按 TOOLS.md 流程）
   - 在 `result` 字段中写入测试结果
   - 添加 history 记录

⚠️ 更新 task.json 时必须保留所有 issue-intake 元数据字段，只修改 status、result、和 history。
```

### deployer

```
你是 Deployer Agent。请执行发布流程。

## 项目信息
- 项目名：{project}
- 项目目录：{projectDir}

## 任务
1. 读取 `~/.openclaw/shared/task.json` 获取任务详情和 PR 信息
2. 按照你的 TOOLS.md 工作流程完成发布
3. 合并 PR、创建 Tag 和 GitHub Release
4. 更新 `~/.openclaw/shared/task.json`：
   - 保留所有现有字段不变
   - 设置 `.status = "released"`
   - 设置 `.deliveryRepo = "<owner/repo>"`（交付仓库地址）
   - 在 `result` 字段中写入 release 信息（release_url, version 等）
   - 添加 history 记录

⚠️ 更新 task.json 时必须保留所有 issue-intake 元数据字段，只修改 status、result、deliveryRepo 和 history。
```

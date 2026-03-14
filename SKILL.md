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


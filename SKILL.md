---
name: issue-intake
description: "Monitor GitHub Issues for feature requests, auto-dispatch to agents team, interact with users via comments, deliver via GitHub Release. Usage: /issue-intake [--repo owner/repo] [--cron] [--init]"
user-invocable: true
metadata:
  { "openclaw": { "requires": { "bins": ["gh", "jq", "git"] } } }
---

# issue-intake — GitHub Issue 需求收集与自动开发系统

You are an orchestrator that bridges GitHub Issues with the agents development team.
Follow these 5 phases exactly. Do not skip phases.

All shell commands use `gh` CLI (already authenticated), `jq`, and `git`. No additional dependencies.

**Key paths:**
- Skill directory: `~/.openclaw/skills/issue-intake/`
- State file: `~/.openclaw/shared/projects/.intake-state.json`
- Task file: `~/.openclaw/shared/task.json`
- Projects root: `~/.openclaw/shared/projects/`

---

## Phase 1 — Parse Arguments & Load State

### 1.1 Parse Arguments

Parse the argument string provided after `/issue-intake`.

| Flag | Default | Description |
|------|---------|-------------|
| `--repo` | _(from state config)_ | Override intake repo (`owner/repo`) |
| `--cron` | `false` | Cron mode: run one poll-dispatch cycle, then exit silently |
| `--init` | `false` | Init mode: create repo, push templates, init labels, then exit |

Store parsed values:
- `REPO_OVERRIDE` = value of `--repo` if provided, else empty
- `CRON_MODE` = true if `--cron` present
- `INIT_MODE` = true if `--init` present

### 1.2 Load State

Read the intake state file. If it doesn't exist, create it with defaults:

```bash
INTAKE_STATE="$HOME/.openclaw/shared/projects/.intake-state.json"

if [ ! -f "$INTAKE_STATE" ]; then
  mkdir -p "$(dirname "$INTAKE_STATE")"
  cat > "$INTAKE_STATE" << 'STATEEOF'
{
  "config": {
    "intakeRepo": "openclaw/community-requests",
    "deliveryOrg": "openclaw",
    "staleTimeoutHours": 72,
    "agentTimeoutHours": 2,
    "maxRetries": 3,
    "defaultLicense": "MIT",
    "approverMode": "author",
    "approvers": [],
    "botGithubUser": "",
    "designerModel": "custom-claude/anthropic/claude-opus-4-6",
    "coderModel": "",
    "reviewerModel": "glm-4.7",
    "testerModel": "glm-4.7",
    "deployerModel": "glm-4.7"
  },
  "processedIssues": {},
  "activeIssue": null,
  "lastPollAt": null
}
STATEEOF
fi
```

Read configuration values:

```bash
INTAKE_REPO=$(jq -r '.config.intakeRepo' "$INTAKE_STATE")
DELIVERY_ORG=$(jq -r '.config.deliveryOrg' "$INTAKE_STATE")
STALE_TIMEOUT=$(jq -r '.config.staleTimeoutHours // 72' "$INTAKE_STATE")
AGENT_TIMEOUT=$(jq -r '.config.agentTimeoutHours // 2' "$INTAKE_STATE")
MAX_RETRIES=$(jq -r '.config.maxRetries // 3' "$INTAKE_STATE")
DEFAULT_LICENSE=$(jq -r '.config.defaultLicense // "MIT"' "$INTAKE_STATE")
APPROVER_MODE=$(jq -r '.config.approverMode // "author"' "$INTAKE_STATE")
APPROVERS=$(jq -r '(.config.approvers // []) | join(",")' "$INTAKE_STATE")
BOT_USER=$(jq -r '.config.botGithubUser // ""' "$INTAKE_STATE")
DESIGNER_MODEL=$(jq -r '.config.designerModel // ""' "$INTAKE_STATE")
CODER_MODEL=$(jq -r '.config.coderModel // ""' "$INTAKE_STATE")
REVIEWER_MODEL=$(jq -r '.config.reviewerModel // ""' "$INTAKE_STATE")
TESTER_MODEL=$(jq -r '.config.testerModel // ""' "$INTAKE_STATE")
DEPLOYER_MODEL=$(jq -r '.config.deployerModel // ""' "$INTAKE_STATE")

# Apply --repo override
if [ -n "$REPO_OVERRIDE" ]; then
  INTAKE_REPO="$REPO_OVERRIDE"
fi

# Auto-detect bot user if not configured
if [ -z "$BOT_USER" ]; then
  BOT_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
  if [ -n "$BOT_USER" ]; then
    # Save it back for future runs
    jq --arg u "$BOT_USER" '.config.botGithubUser = $u' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
  fi
fi
```

Read the active issue number:

```bash
ACTIVE_ISSUE=$(jq -r '.activeIssue // empty' "$INTAKE_STATE")
```

### 1.3 Load Task (if active)

If there is an active issue, load `task.json`:

```bash
TASK_JSON="$HOME/.openclaw/shared/task.json"

if [ -n "$ACTIVE_ISSUE" ] && [ -f "$TASK_JSON" ]; then
  TASK_STATUS=$(jq -r '.status' "$TASK_JSON")
  TASK_SOURCE=$(jq -r '.source // "manual"' "$TASK_JSON")
  TASK_PROJECT=$(jq -r '.project' "$TASK_JSON")
  PROJECT_DIR=$(jq -r '.projectDir' "$TASK_JSON")
  ISSUE_NUMBER=$(jq -r '.issueNumber // empty' "$TASK_JSON")
  ISSUE_REPO=$(jq -r '.issueRepo // empty' "$TASK_JSON")
  DELIVERY_REPO=$(jq -r '.deliveryRepo // empty' "$TASK_JSON")
  AGENT_SPAWNED=$(jq -r '.agentSpawned // false' "$TASK_JSON")
  RETRY_COUNT=$(jq -r '.retryCount // 0' "$TASK_JSON")
  LAST_STATUS_CHANGE=$(jq -r '.lastStatusChange // empty' "$TASK_JSON")
  DESIGN_FEEDBACK=$(jq -r '.designFeedback // empty' "$TASK_JSON")
fi
```

### 1.4 Route

- If `INIT_MODE` is true → go to **Phase 2**
- If `ACTIVE_ISSUE` is non-empty → go to **Phase 4** (State Machine Dispatch)
- Otherwise → go to **Phase 3** (Poll New Issues)

---

## Phase 2 — Init Mode (`--init`)

This phase creates the intake repository and pushes all template files.

### 2.1 Create Repository

```bash
# Check if repo exists
if ! gh repo view "$INTAKE_REPO" &>/dev/null; then
  gh repo create "$INTAKE_REPO" --public --description "🦀 Submit development requests — our AI team builds them for you!" --license MIT
  echo "✅ Created repository: $INTAKE_REPO"
else
  echo "ℹ️ Repository $INTAKE_REPO already exists"
fi
```

### 2.2 Clone and Push Templates

```bash
SKILL_DIR="$HOME/.openclaw/skills/issue-intake"
WORK_DIR=$(mktemp -d)

# Clone the repo (or init if empty)
gh repo clone "$INTAKE_REPO" "$WORK_DIR" 2>/dev/null || (cd "$WORK_DIR" && git init && git remote add origin "https://github.com/$INTAKE_REPO.git")

cd "$WORK_DIR"

# Create directory structure
mkdir -p .github/ISSUE_TEMPLATE

# Copy Issue Template
cp "$SKILL_DIR/scripts/templates/feature-request.yml" .github/ISSUE_TEMPLATE/feature-request.yml

# Copy README
cp "$SKILL_DIR/scripts/templates/README.md" README.md

# Copy CONTRIBUTING
cp "$SKILL_DIR/scripts/templates/CONTRIBUTING.md" CONTRIBUTING.md

# Copy LICENSE (if not already present)
if [ ! -f LICENSE ]; then
  cp "$SKILL_DIR/scripts/templates/LICENSE" LICENSE
fi

# Commit and push
git add -A
if git diff --cached --quiet; then
  echo "ℹ️ No changes to push"
else
  git commit -m "chore: initialize intake repository with templates"
  git push -u origin main 2>/dev/null || git push -u origin master
  echo "✅ Templates pushed to $INTAKE_REPO"
fi

# Cleanup
rm -rf "$WORK_DIR"
```

### 2.3 Initialize Labels

```bash
bash "$SKILL_DIR/scripts/init-labels.sh" "$INTAKE_REPO"
echo "✅ Labels initialized"
```

### 2.4 Exit

Print success summary and **stop here** (do not continue to Phase 3/4/5):

```
✅ Issue Intake initialized!
- Repository: $INTAKE_REPO
- Issue Template: feature-request.yml
- Labels: 10 labels created
- Ready to receive requests via GitHub Issues

To start polling: /issue-intake --cron
To set up cron: openclaw cron add --schedule "*/5 * * * *" --command "/issue-intake --cron" --name "issue-intake-poll"
```

---

## Phase 3 — Poll New Issues

This phase runs when there is no active issue being processed.

### 3.1 Fetch New Issues

```bash
ISSUES_JSON=$(gh issue list --repo "$INTAKE_REPO" --label "new-request" --state open --json number,title,body,createdAt,author --limit 10)
```

### 3.2 Filter Already-Processed

```bash
# Get list of already-processed issue numbers
PROCESSED=$(jq -r '.processedIssues | keys[]' "$INTAKE_STATE")

# Filter out processed issues, take the oldest one
NEW_ISSUE=$(echo "$ISSUES_JSON" | jq --argjson processed "$(jq '.processedIssues | keys | map(tonumber)' "$INTAKE_STATE")" '
  [.[] | select(.number as $n | ($processed | index($n)) | not)]
  | sort_by(.createdAt)
  | first
')
```

### 3.3 Check Result

If `NEW_ISSUE` is null or empty:
- Update `lastPollAt` in intake-state.json
- If `CRON_MODE`: exit silently
- Otherwise: print "No new issues found" and stop

```bash
if [ "$NEW_ISSUE" = "null" ] || [ -z "$NEW_ISSUE" ]; then
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastPollAt = $t' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
  echo "ℹ️ No new issues to process"
  # STOP HERE
fi
```

### 3.4 Parse Issue & Initialize Project

Extract fields from the new issue:

```bash
ISSUE_NUMBER=$(echo "$NEW_ISSUE" | jq -r '.number')
ISSUE_TITLE=$(echo "$NEW_ISSUE" | jq -r '.title')
ISSUE_BODY=$(echo "$NEW_ISSUE" | jq -r '.body')
ISSUE_AUTHOR=$(echo "$NEW_ISSUE" | jq -r '.author.login')

# Derive project name from title
# Remove [Request] prefix, convert to slug
PROJECT_NAME=$(echo "$ISSUE_TITLE" | sed 's/^\[Request\] *//i' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g' | tr ' ' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-50)

PROJECT_DIR="$HOME/.openclaw/shared/projects/$PROJECT_NAME"
mkdir -p "$PROJECT_DIR"
```

Parse the structured Issue body into sections. The body uses `### ` headings from the YAML form template. Each form field is rendered by GitHub as a `### Label` heading followed by the content:

```bash
# Extract sections from the GitHub-rendered YAML form body
# GitHub renders YAML form fields as: ### Label\n\nContent\n\n
# We parse each section by heading

DESCRIPTION=$(echo "$ISSUE_BODY" | awk '/^### 📝 Description/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
REQUIREMENTS=$(echo "$ISSUE_BODY" | awk '/^### 📋 Requirements/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
CONSTRAINTS=$(echo "$ISSUE_BODY" | awk '/^### 🔧 Constraints/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
REFERENCES=$(echo "$ISSUE_BODY" | awk '/^### 📎 References/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
LICENSE_CHOICE=$(echo "$ISSUE_BODY" | awk '/^### 📄 License/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//' | head -1)

# Default license if not specified
if [ -z "$LICENSE_CHOICE" ] || [ "$LICENSE_CHOICE" = "_No response_" ]; then
  LICENSE_CHOICE="$DEFAULT_LICENSE"
fi
```

Generate `requirements.md`:

```bash
cat > "$PROJECT_DIR/requirements.md" << REQEOF
# 需求说明书：$ISSUE_TITLE

> 来源：GitHub Issue #$ISSUE_NUMBER ($INTAKE_REPO)
> 提交者：@$ISSUE_AUTHOR
> 日期：$(date -u +%Y-%m-%dT%H:%M:%SZ)

## 需求描述

$DESCRIPTION

## 具体要求

$REQUIREMENTS

## 约束条件

${CONSTRAINTS:-无特殊约束}

## 参考资料

${REFERENCES:-无}

## 许可协议

$LICENSE_CHOICE
REQEOF
```

Generate `task.json`:

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$HOME/.openclaw/shared/task.json" << TASKEOF
{
  "project": "$PROJECT_NAME",
  "title": "$ISSUE_TITLE",
  "status": "pending",
  "source": "github-issue",
  "created": "$NOW",
  "projectDir": "$PROJECT_DIR",
  "requirementsDoc": "$PROJECT_DIR/requirements.md",
  "issueNumber": $ISSUE_NUMBER,
  "issueRepo": "$INTAKE_REPO",
  "deliveryRepo": null,
  "retryCount": 0,
  "maxRetries": $MAX_RETRIES,
  "lastStatusChange": "$NOW",
  "designFeedback": null,
  "agentSpawned": false,
  "history": [
    {
      "timestamp": "$NOW",
      "from": null,
      "to": "pending",
      "actor": "issue-intake"
    }
  ]
}
TASKEOF
```

Update intake-state.json:

```bash
jq --arg n "$ISSUE_NUMBER" --arg p "$PROJECT_NAME" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .activeIssue = ($n | tonumber) |
  .processedIssues[$n] = {
    "project": $p,
    "status": "pending",
    "createdAt": $t,
    "completedAt": null
  } |
  .lastPollAt = $t
' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
```

### 3.5 Update Issue Labels & Comment

```bash
# Remove new-request, add designing
gh issue edit "$ISSUE_NUMBER" --repo "$INTAKE_REPO" --remove-label "new-request" --add-label "designing"

# Post status comment
gh issue comment "$ISSUE_NUMBER" --repo "$INTAKE_REPO" --body "🎨 **设计中...**

我们的 AI 设计师正在分析您的需求，稍后将提供技术方案供您确认。

> 项目名称：\`$PROJECT_NAME\`"
```

### 3.6 Proceed

Now there is an active issue. If NOT in cron mode, proceed directly to **Phase 4**.
If in cron mode, exit — the next cron run will pick up at Phase 4.

---

## Phase 4 — State Machine Dispatch

This is the core dispatch engine. Read `task.json` status and execute the appropriate action.

### 4.0 Pre-check: Failure Detection

Before dispatching, check if a spawned agent has timed out:

```bash
if [ "$AGENT_SPAWNED" = "true" ] && [ -n "$LAST_STATUS_CHANGE" ]; then
  # Calculate hours elapsed since last status change
  LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_STATUS_CHANGE" "+%s" 2>/dev/null || date -d "$LAST_STATUS_CHANGE" "+%s" 2>/dev/null)
  NOW_EPOCH=$(date -u "+%s")
  HOURS_ELAPSED=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))

  if [ "$HOURS_ELAPSED" -ge "$AGENT_TIMEOUT" ]; then
    echo "⚠️ Agent timeout detected ($HOURS_ELAPSED hours). Status: $TASK_STATUS"

    # Increment retry count
    NEW_RETRY=$((RETRY_COUNT + 1))

    if [ "$NEW_RETRY" -gt "$MAX_RETRIES" ]; then
      # Escalate — too many retries
      echo "❌ Max retries ($MAX_RETRIES) exceeded. Escalating to needs-help."

      jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .agentSpawned = false |
        .retryCount = (.retryCount + 1) |
        .lastStatusChange = $t
      ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

      if [ -n "$ISSUE_NUMBER" ] && [ "$TASK_SOURCE" = "github-issue" ]; then
        gh issue edit "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --add-label "needs-help"
        gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "⚠️ **需要人工介入**

此需求在 \`$TASK_STATUS\` 阶段处理超时，已超过最大重试次数（$MAX_RETRIES 次）。

我们的团队会尽快查看。抱歉给您带来不便！"
      fi

      # STOP — manual intervention needed
      exit 0
    fi

    # Reset agentSpawned to allow re-spawn
    jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$NEW_RETRY" '
      .agentSpawned = false |
      .retryCount = $r |
      .lastStatusChange = $t
    ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

    AGENT_SPAWNED="false"
    RETRY_COUNT=$NEW_RETRY
    echo "🔄 Retry $NEW_RETRY/$MAX_RETRIES — re-spawning agent for status: $TASK_STATUS"
  fi
fi
```

### 4.1 Status: `pending` — Spawn Designer

**Guard:** If `agentSpawned` is true, skip (agent already running). Wait for next cycle.

```bash
if [ "$AGENT_SPAWNED" = "true" ]; then
  echo "⏳ Designer agent already spawned, waiting..."
  # STOP — wait for next cron cycle
fi
```

**Action:** Spawn a designer subagent.

Build the feedback section (if user previously gave design feedback):

```bash
FEEDBACK_SECTION=""
if [ -n "$DESIGN_FEEDBACK" ] && [ "$DESIGN_FEEDBACK" != "null" ]; then
  FEEDBACK_SECTION="
## ⚠️ 用户反馈（请务必根据以下反馈调整设计）

$DESIGN_FEEDBACK
"
fi

# Also check if feedback.md exists
FEEDBACK_FILE="$PROJECT_DIR/feedback.md"
if [ -f "$FEEDBACK_FILE" ]; then
  FEEDBACK_SECTION="
## ⚠️ 用户反馈（请务必根据以下反馈调整设计）

$(cat "$FEEDBACK_FILE")
"
fi
```

Spawn designer via `sessions_spawn`:

```
sessions_spawn role=designer task="
你是 designer，负责技术方案设计。

## 任务
为项目 **$TASK_PROJECT** 做技术设计。

## 输入
- 需求说明书：$PROJECT_DIR/requirements.md（务必完整阅读）
- 任务状态：~/.openclaw/shared/task.json

$FEEDBACK_SECTION

## 要求
1. 仔细阅读需求说明书，理解用户需求
2. 输出完整的技术设计文档到 $PROJECT_DIR/design.md
3. 设计应包含：系统架构、技术选型、核心模块设计、数据流、文件结构、实现计划
4. 完成后更新 task.json：
   - status → designed
   - agentSpawned → false
   - lastStatusChange → 当前时间
   - 在 history 数组中追加一条记录

## 约束
- 所有产物写到 $PROJECT_DIR/ 下
- 不要写入 ~/.openclaw/workspace/
"
```

If the `DESIGNER_MODEL` is non-empty, add `model=$DESIGNER_MODEL` to the spawn command.

After spawning, update task.json:

```bash
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .agentSpawned = true |
  .lastStatusChange = $t
' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
```

**STOP** — exit and wait for designer to complete.

### 4.2 Status: `designed` — Post Design & Transition to Awaiting Approval

**Action:** Read the design document and transition.

If `source` is `"github-issue"`, post the design to the Issue:

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
  # Read design.md content
  DESIGN_CONTENT=$(cat "$PROJECT_DIR/design.md")

  # Generate approval hint based on approverMode
  case "$APPROVER_MODE" in
    "author")
      ISSUE_AUTHOR=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json author --jq '.author.login')
      APPROVAL_HINT="👤 **确认权限：** 仅 Issue 提交者 @${ISSUE_AUTHOR} 的回复视为有效确认。"
      ;;
    "allowlist")
      MENTIONS=$(echo "$APPROVERS" | sed 's/,/ @/g; s/^/@/')
      APPROVAL_HINT="👤 **确认权限：** 仅以下用户的回复视为有效确认：${MENTIONS}"
      ;;
    "any")
      APPROVAL_HINT="👤 **确认权限：** 任何用户均可确认。"
      ;;
    *)
      ISSUE_AUTHOR=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json author --jq '.author.login')
      APPROVAL_HINT="👤 **确认权限：** 仅 Issue 提交者 @${ISSUE_AUTHOR} 的回复视为有效确认。"
      ;;
  esac

  # Post design to Issue
  # Note: GitHub comments have a 65536 character limit. If design is very long,
  # post a summary with a link to the full document.
  DESIGN_LENGTH=${#DESIGN_CONTENT}
  if [ "$DESIGN_LENGTH" -gt 50000 ]; then
    # Truncate and add note
    DESIGN_EXCERPT="${DESIGN_CONTENT:0:50000}

---
> ⚠️ 设计文档过长，已截断。完整版本请查看项目文件。"
  else
    DESIGN_EXCERPT="$DESIGN_CONTENT"
  fi

  COMMENT_BODY="📋 **设计方案已完成！**

请查看下方的技术方案，确认后我们将开始开发：

---

<details>
<summary>📖 点击展开完整设计方案</summary>

$DESIGN_EXCERPT

</details>

---

**请回复以下内容确认：**
- 👍 或 \`LGTM\` / \`approved\` → 确认通过，开始开发
- 具体修改意见 → 我们将调整方案后重新提交

$APPROVAL_HINT

> ⏰ 72 小时内未回复将自动关闭此需求"

  gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "$COMMENT_BODY"

  # Update labels
  gh issue edit "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --remove-label "designing" --add-label "awaiting-feedback" 2>/dev/null || true
fi

# Record the time we posted the design (for timeout tracking)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Update task.json → awaiting_approval
jq --arg t "$NOW" '
  .status = "awaiting_approval" |
  .agentSpawned = false |
  .lastStatusChange = $t |
  .history += [{
    "timestamp": $t,
    "from": "designed",
    "to": "awaiting_approval",
    "actor": "issue-intake"
  }]
' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

# Update intake-state.json
jq --arg n "$ISSUE_NUMBER" '.processedIssues[$n].status = "awaiting_approval"' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
```

**STOP** — wait for user feedback (next cron cycle).

### 4.3 Status: `awaiting_approval` — Check Feedback or Skip

**Branch by source:**

#### 4.3.1 Source = `github-issue`

Check the Issue for new comments from authorized users after the bot's last design comment.

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then

  # Get all comments on the issue
  COMMENTS_JSON=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json comments --jq '.comments')

  # Find the last bot design comment timestamp
  # The bot's design comment contains "设计方案已完成"
  LAST_DESIGN_TIME=$(echo "$COMMENTS_JSON" | jq -r --arg bot "$BOT_USER" '
    [.[] | select(.author.login == $bot and (.body | contains("设计方案已完成")))] | last | .createdAt // empty
  ')

  if [ -z "$LAST_DESIGN_TIME" ]; then
    # Fallback to lastStatusChange
    LAST_DESIGN_TIME="$LAST_STATUS_CHANGE"
  fi

  # Get the Issue author
  ISSUE_AUTHOR=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json author --jq '.author.login')

  # Filter comments after the design was posted, excluding bot comments
  FEEDBACK_COMMENTS=$(echo "$COMMENTS_JSON" | jq -r --arg since "$LAST_DESIGN_TIME" --arg bot "$BOT_USER" '
    [.[] | select(.createdAt > $since and .author.login != $bot)]
  ')

  FEEDBACK_COUNT=$(echo "$FEEDBACK_COMMENTS" | jq 'length')

  if [ "$FEEDBACK_COUNT" -gt 0 ]; then
    # Check each comment from newest to oldest for authorized users
    FOUND_FEEDBACK="false"

    for i in $(seq 0 $((FEEDBACK_COUNT - 1))); do
      COMMENTER=$(echo "$FEEDBACK_COMMENTS" | jq -r ".[$i].author.login")
      COMMENT_BODY=$(echo "$FEEDBACK_COMMENTS" | jq -r ".[$i].body")

      # Check authorization
      IS_AUTHORIZED="false"
      case "$APPROVER_MODE" in
        "author")
          [ "$COMMENTER" = "$ISSUE_AUTHOR" ] && IS_AUTHORIZED="true"
          ;;
        "allowlist")
          echo ",$APPROVERS," | grep -q ",$COMMENTER," && IS_AUTHORIZED="true"
          ;;
        "any")
          IS_AUTHORIZED="true"
          ;;
        *)
          [ "$COMMENTER" = "$ISSUE_AUTHOR" ] && IS_AUTHORIZED="true"
          ;;
      esac

      if [ "$IS_AUTHORIZED" != "true" ]; then
        continue
      fi

      FOUND_FEEDBACK="true"

      # Check if it's an approval
      if echo "$COMMENT_BODY" | grep -qiE '^\s*(👍|LGTM|approved|确认|通过|OK|没问题|approve|looks good)\s*$'; then
        # APPROVED — transition to in_progress
        echo "✅ User approved the design"

        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        jq --arg t "$NOW" '
          .status = "in_progress" |
          .agentSpawned = false |
          .retryCount = 0 |
          .lastStatusChange = $t |
          .designFeedback = null |
          .history += [{
            "timestamp": $t,
            "from": "awaiting_approval",
            "to": "in_progress",
            "actor": "issue-intake"
          }]
        ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

        jq --arg n "$ISSUE_NUMBER" '.processedIssues[$n].status = "in_progress"' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"

        # Update labels
        gh issue edit "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --remove-label "awaiting-feedback" --add-label "in-progress" 2>/dev/null || true

        gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "💻 **开发中...**

方案已确认，AI 工程师正在编码实现。"

        # If not cron mode, continue to dispatch in_progress
        # If cron mode, exit — next cycle handles it
        break
      else
        # CHANGE REQUEST — save feedback and revert to designed
        echo "📝 User requested changes"

        # Save feedback
        echo "$COMMENT_BODY" > "$PROJECT_DIR/feedback.md"

        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        jq --arg t "$NOW" --arg fb "$COMMENT_BODY" '
          .status = "designed" |
          .agentSpawned = false |
          .retryCount = 0 |
          .lastStatusChange = $t |
          .designFeedback = $fb |
          .history += [{
            "timestamp": $t,
            "from": "awaiting_approval",
            "to": "designed",
            "actor": "issue-intake",
            "note": "User requested design changes"
          }]
        ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

        # Note: we go back to "designed" so that next cron cycle, status "designed"
        # is actually not correct — we need "pending" to re-trigger designer.
        # Actually per the state machine: designed → awaiting_approval → designed means
        # we need to re-run designer. So let's set status to "pending" to re-trigger.
        jq --arg t "$NOW" --arg fb "$COMMENT_BODY" '
          .status = "pending" |
          .agentSpawned = false |
          .retryCount = 0 |
          .lastStatusChange = $t |
          .designFeedback = $fb |
          .history += [{
            "timestamp": $t,
            "from": "designed",
            "to": "pending",
            "actor": "issue-intake",
            "note": "Re-trigger designer with feedback"
          }]
        ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

        jq --arg n "$ISSUE_NUMBER" '.processedIssues[$n].status = "pending"' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"

        # Update labels
        gh issue edit "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --remove-label "awaiting-feedback" --add-label "designing" 2>/dev/null || true

        gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "🎨 **收到修改意见，重新设计中...**

感谢您的反馈！我们的 AI 设计师正在根据您的意见调整方案。"

        break
      fi
    done

    if [ "$FOUND_FEEDBACK" = "false" ]; then
      echo "ℹ️ Comments found but none from authorized users. Waiting..."
    fi

  else
    # No new comments — check for stale timeout
    DESIGN_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_DESIGN_TIME" "+%s" 2>/dev/null || date -d "$LAST_DESIGN_TIME" "+%s" 2>/dev/null)
    NOW_EPOCH=$(date -u "+%s")
    HOURS_WAITING=$(( (NOW_EPOCH - DESIGN_EPOCH) / 3600 ))

    if [ "$HOURS_WAITING" -ge "$STALE_TIMEOUT" ]; then
      echo "⏰ Stale timeout ($HOURS_WAITING hours). Closing issue."

      # Close as stale
      gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "⏰ **自动关闭**

72 小时未收到回复，此需求已自动关闭。

如仍需要，请重新打开此 Issue 或提交新的请求。"

      gh issue close "$ISSUE_NUMBER" --repo "$ISSUE_REPO"
      gh issue edit "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --add-label "stale" --remove-label "awaiting-feedback" 2>/dev/null || true

      # Clear active issue
      NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      jq --arg n "$ISSUE_NUMBER" --arg t "$NOW" '
        .activeIssue = null |
        .processedIssues[$n].status = "stale" |
        .processedIssues[$n].completedAt = $t
      ' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"

      # STOP
    else
      echo "⏳ Waiting for user feedback ($HOURS_WAITING/$STALE_TIMEOUT hours)..."
      # STOP — wait for next cron cycle
    fi
  fi

fi
```

#### 4.3.2 Source = `manual`

Skip — the main agent (Claw) handles `awaiting_approval` for manual tasks via the existing WORKFLOW.md flow.

```bash
if [ "$TASK_SOURCE" = "manual" ] || [ "$TASK_SOURCE" != "github-issue" ]; then
  echo "ℹ️ Manual task — awaiting_approval handled by main agent. Skipping."
  # STOP
fi
```

### 4.4 Status: `in_progress` — Spawn Coder

**Guard:** If `agentSpawned` is true, skip.

```bash
if [ "$AGENT_SPAWNED" = "true" ]; then
  echo "⏳ Coder agent already spawned, waiting..."
  # STOP
fi
```

**Action:** Spawn coder subagent.

```
sessions_spawn role=coder task="
你是 coder，负责编码实现。

## 任务
为项目 **$TASK_PROJECT** 编码实现。

## 输入
- 技术设计文档：$PROJECT_DIR/design.md（务必完整阅读）
- 需求说明书：$PROJECT_DIR/requirements.md
- 任务状态：~/.openclaw/shared/task.json

## 要求
1. 仔细阅读技术设计文档，理解架构和实现方案
2. 在 $PROJECT_DIR/src/ 下编写完整的源代码
3. 编写 $PROJECT_DIR/DEPLOYMENT.md 初版（部署实施说明），包含：
   - 环境要求（运行时版本、系统依赖）
   - 安装步骤（step-by-step 安装命令）
   - 配置说明（环境变量、配置文件）
   - 启动/运行命令
   - 验证方法（如何确认部署成功）
   - 常见问题排查
4. 创建 GitHub 仓库 $DELIVERY_ORG/$TASK_PROJECT（如不存在）：
   gh repo create $DELIVERY_ORG/$TASK_PROJECT --public --description \"$ISSUE_TITLE\" || true
5. 将代码推送到仓库
6. 完成后更新 task.json：
   - status → in_review
   - deliveryRepo → \"$DELIVERY_ORG/$TASK_PROJECT\"
   - agentSpawned → false
   - lastStatusChange → 当前时间
   - 在 history 数组中追加一条记录

## 约束
- 所有代码写到 $PROJECT_DIR/src/ 下
- DEPLOYMENT.md 写到 $PROJECT_DIR/DEPLOYMENT.md
- 不要写入 ~/.openclaw/workspace/
"
```

If `CODER_MODEL` is non-empty, add `model=$CODER_MODEL` to the spawn command.

After spawning, update task.json:

```bash
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .agentSpawned = true |
  .lastStatusChange = $t
' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
```

If `source` is `github-issue`, post status update:

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
  gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "💻 **开发中...**

AI 工程师正在根据确认的设计方案编码实现。" 2>/dev/null || true
fi
```

**STOP** — wait for coder to complete.

### 4.5 Status: `in_review` — Spawn Reviewer

**Guard:** If `agentSpawned` is true, skip.

```bash
if [ "$AGENT_SPAWNED" = "true" ]; then
  echo "⏳ Reviewer agent already spawned, waiting..."
  # STOP
fi
```

**Action:** Spawn reviewer subagent.

```
sessions_spawn role=reviewer task="
你是 reviewer，负责代码审查。

## 任务
审查项目 **$TASK_PROJECT** 的代码实现。

## 输入
- 技术设计文档：$PROJECT_DIR/design.md
- 源代码：$PROJECT_DIR/src/
- 部署说明：$PROJECT_DIR/DEPLOYMENT.md（如有）
- 任务状态：~/.openclaw/shared/task.json

## 要求
1. 检查代码是否符合设计文档的架构和要求
2. 检查代码质量：可读性、错误处理、边界条件
3. 检查是否有安全问题
4. 输出审查报告到 $PROJECT_DIR/review.md
5. 判定结果：
   - **通过**：更新 task.json status → approved
   - **不通过**：更新 task.json status → in_progress（回退，让 coder 修改）
     在 review.md 中详细说明需要修改的地方
6. 无论通过与否，都要更新：
   - agentSpawned → false
   - lastStatusChange → 当前时间
   - 在 history 数组中追加一条记录

## 约束
- 审查报告写到 $PROJECT_DIR/review.md
- 不要写入 ~/.openclaw/workspace/
"
```

If `REVIEWER_MODEL` is non-empty, add `model=$REVIEWER_MODEL` to the spawn command.

After spawning, update task.json:

```bash
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .agentSpawned = true |
  .lastStatusChange = $t
' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
```

If `source` is `github-issue`, post status update:

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
  gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "🔍 **代码审查中...**

开发完成，正在进行代码审查。" 2>/dev/null || true
fi
```

**STOP**.

### 4.6 Status: `approved` — Spawn Tester

**Guard:** If `agentSpawned` is true, skip.

```bash
if [ "$AGENT_SPAWNED" = "true" ]; then
  echo "⏳ Tester agent already spawned, waiting..."
  # STOP
fi
```

**Action:** Spawn tester subagent.

```
sessions_spawn role=tester task="
你是 tester，负责测试验证。

## 任务
测试项目 **$TASK_PROJECT** 的实现。

## 输入
- 技术设计文档：$PROJECT_DIR/design.md
- 需求说明书：$PROJECT_DIR/requirements.md
- 源代码：$PROJECT_DIR/src/
- 审查报告：$PROJECT_DIR/review.md
- 任务状态：~/.openclaw/shared/task.json

## 要求
1. 根据需求说明书和设计文档，验证功能是否正确实现
2. 编写并运行测试（单元测试、集成测试视项目而定）
3. 输出测试报告到 $PROJECT_DIR/test-report.md
4. 判定结果：
   - **通过**：更新 task.json status → tested
   - **不通过**：更新 task.json status → in_progress（回退，让 coder 修复）
     在 test-report.md 中详细说明失败的测试和原因
5. 无论通过与否，都要更新：
   - agentSpawned → false
   - lastStatusChange → 当前时间
   - 在 history 数组中追加一条记录

## 约束
- 测试报告写到 $PROJECT_DIR/test-report.md
- 测试代码写到 $PROJECT_DIR/src/（或 $PROJECT_DIR/tests/）
- 不要写入 ~/.openclaw/workspace/
"
```

If `TESTER_MODEL` is non-empty, add `model=$TESTER_MODEL` to the spawn command.

After spawning, update task.json:

```bash
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .agentSpawned = true |
  .lastStatusChange = $t
' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
```

If `source` is `github-issue`, post status update:

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
  gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "✅ **审查通过，测试中...**

代码审查通过，正在执行自动化测试。" 2>/dev/null || true
fi
```

**STOP**.

### 4.7 Status: `tested` — Spawn Deployer

**Guard:** If `agentSpawned` is true, skip.

```bash
if [ "$AGENT_SPAWNED" = "true" ]; then
  echo "⏳ Deployer agent already spawned, waiting..."
  # STOP
fi
```

**Action:** Spawn deployer subagent.

```
sessions_spawn role=deployer task="
你是 deployer，负责打包发布。

## 任务
发布项目 **$TASK_PROJECT** 到 GitHub。

## 输入
- 技术设计文档：$PROJECT_DIR/design.md
- 源代码：$PROJECT_DIR/src/
- 测试报告：$PROJECT_DIR/test-report.md
- 部署说明：$PROJECT_DIR/DEPLOYMENT.md
- 交付仓库：$DELIVERY_REPO（已由 coder 创建并推送代码）
- 任务状态：~/.openclaw/shared/task.json

## 要求
1. 校验并补充完善 $PROJECT_DIR/DEPLOYMENT.md：
   - 确保与实际发布产物一致
   - 补充发布后才能确定的信息（如 Release 下载链接、版本号）
   - 验证安装步骤可执行
2. 将最终版 DEPLOYMENT.md 推送到仓库
3. 生成 Release Notes 到 $PROJECT_DIR/release-notes.md，包含：
   - 版本号与项目简介
   - 功能摘要
   - 📦 部署说明引用：「详细部署步骤请参见 [DEPLOYMENT.md](./DEPLOYMENT.md)」
   - 下载/使用说明
4. 在 $DELIVERY_REPO 创建 GitHub Release：
   gh release create v1.0.0 --repo $DELIVERY_REPO --title \"v1.0.0 - $ISSUE_TITLE\" --notes-file $PROJECT_DIR/release-notes.md
5. 完成后更新 task.json：
   - status → released
   - agentSpawned → false
   - lastStatusChange → 当前时间
   - 在 history 数组中追加一条记录

## 约束
- release-notes.md 写到 $PROJECT_DIR/release-notes.md
- 不要写入 ~/.openclaw/workspace/
"
```

If `DEPLOYER_MODEL` is non-empty, add `model=$DEPLOYER_MODEL` to the spawn command.

After spawning, update task.json:

```bash
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .agentSpawned = true |
  .lastStatusChange = $t
' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
```

If `source` is `github-issue`, post status update:

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
  gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "🧪 **测试通过，发布中...**

所有测试通过，正在打包发布。" 2>/dev/null || true
fi
```

**STOP**.

### 4.8 Status: `released` — Post Release & Close Issue

**Action:** Finalize delivery.

If `source` is `github-issue`:

```bash
if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
  # Get release URL
  RELEASE_URL="https://github.com/$DELIVERY_REPO/releases/tag/v1.0.0"

  # Try to get actual release URL
  ACTUAL_RELEASE=$(gh release view --repo "$DELIVERY_REPO" --json url --jq '.url' 2>/dev/null || echo "$RELEASE_URL")
  [ -n "$ACTUAL_RELEASE" ] && RELEASE_URL="$ACTUAL_RELEASE"

  # Post release notification
  gh issue comment "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --body "🚀 **已发布！**

您的需求已完成交付！

📦 **仓库地址：** https://github.com/$DELIVERY_REPO
🏷️ **Release 地址：** $RELEASE_URL

感谢使用 OpenClaw！如有问题欢迎新建 Issue。"

  # Update labels and close
  gh issue edit "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --remove-label "releasing" --add-label "completed" 2>/dev/null || true
  gh issue close "$ISSUE_NUMBER" --repo "$ISSUE_REPO"
fi
```

**Proceed to Phase 5** for cleanup.

---

## Phase 5 — Cleanup & Exit

### 5.1 Archive Completed Task

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Update intake-state.json
if [ -n "$ISSUE_NUMBER" ]; then
  jq --arg n "$ISSUE_NUMBER" --arg t "$NOW" '
    .activeIssue = null |
    .processedIssues[$n].status = "released" |
    .processedIssues[$n].completedAt = $t
  ' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
else
  jq '.activeIssue = null' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
fi
```

### 5.2 Summary

Print completion summary:

```
✅ Task completed!
- Project: $TASK_PROJECT
- Issue: #$ISSUE_NUMBER ($ISSUE_REPO)
- Delivery: https://github.com/$DELIVERY_REPO
- Status: released
```

### 5.3 Exit

If in cron mode, exit silently.
Otherwise, ask if the user wants to continue polling for new issues.

---

## Appendix A — Helper Functions Reference

These are the logical operations used throughout the phases. They are NOT separate scripts — implement them inline using `exec` (shell commands) or agent logic as appropriate.

### A.1 sync_labels

Remove all status labels, then add the one for the new status:

```bash
sync_labels() {
  local issue_number="$1"
  local new_status="$2"
  local repo="$3"

  # Remove all status labels
  for label in designing awaiting-feedback in-progress in-review testing releasing; do
    gh issue edit "$issue_number" --repo "$repo" --remove-label "$label" 2>/dev/null || true
  done

  # Add new status label
  case "$new_status" in
    "pending")           gh issue edit "$issue_number" --repo "$repo" --remove-label "new-request" --add-label "designing" ;;
    "designed")          gh issue edit "$issue_number" --repo "$repo" --add-label "awaiting-feedback" ;;
    "awaiting_approval") ;; # Keep awaiting-feedback
    "in_progress")       gh issue edit "$issue_number" --repo "$repo" --add-label "in-progress" ;;
    "in_review")         gh issue edit "$issue_number" --repo "$repo" --add-label "in-review" ;;
    "approved")          gh issue edit "$issue_number" --repo "$repo" --add-label "testing" ;;
    "tested")            gh issue edit "$issue_number" --repo "$repo" --add-label "releasing" ;;
    "released")          gh issue edit "$issue_number" --repo "$repo" --add-label "completed" ;;
  esac
}
```

### A.2 update_task_status

Atomically update task.json status with history:

```bash
update_task_status() {
  local new_status="$1"
  local actor="$2"
  local note="$3"

  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local old_status=$(jq -r '.status' "$TASK_JSON")

  if [ -n "$note" ]; then
    jq --arg s "$new_status" --arg t "$now" --arg old "$old_status" --arg a "$actor" --arg n "$note" '
      .status = $s |
      .agentSpawned = false |
      .lastStatusChange = $t |
      .history += [{
        "timestamp": $t,
        "from": $old,
        "to": $s,
        "actor": $a,
        "note": $n
      }]
    ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
  else
    jq --arg s "$new_status" --arg t "$now" --arg old "$old_status" --arg a "$actor" '
      .status = $s |
      .agentSpawned = false |
      .lastStatusChange = $t |
      .history += [{
        "timestamp": $t,
        "from": $old,
        "to": $s,
        "actor": $a
      }]
    ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
  fi
}
```

### A.3 post_comment

```bash
post_comment() {
  local issue_number="$1"
  local repo="$2"
  local body="$3"
  gh issue comment "$issue_number" --repo "$repo" --body "$body"
}
```

---

## Appendix B — Cron Setup

To enable automatic polling, set up a cron job:

```bash
openclaw cron add --schedule "*/5 * * * *" --command "/issue-intake --cron" --name "issue-intake-poll"
```

To check cron status:
```bash
openclaw cron list
```

To remove cron:
```bash
openclaw cron remove --name "issue-intake-poll"
```

---

## Appendix C — Configuration Reference

All configuration is stored in `~/.openclaw/shared/projects/.intake-state.json` under the `config` key.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `intakeRepo` | string | `openclaw/community-requests` | GitHub repo for collecting requests |
| `deliveryOrg` | string | `openclaw` | GitHub org for delivery repos |
| `staleTimeoutHours` | number | `72` | Hours before auto-closing unresponsive issues |
| `agentTimeoutHours` | number | `2` | Hours before considering an agent timed out |
| `maxRetries` | number | `3` | Max retries per stage before escalation |
| `defaultLicense` | string | `MIT` | Default license for delivered projects |
| `approverMode` | string | `author` | Who can approve designs: `author`, `allowlist`, `any` |
| `approvers` | array | `[]` | Authorized approver GitHub usernames (for `allowlist` mode) |
| `botGithubUser` | string | `""` | Bot's GitHub username (auto-detected if empty) |
| `designerModel` | string | `custom-claude/anthropic/claude-opus-4-6` | Model for designer agent |
| `coderModel` | string | `""` | Model for coder agent (empty = default) |
| `reviewerModel` | string | `glm-4.7` | Model for reviewer agent |
| `testerModel` | string | `glm-4.7` | Model for tester agent |
| `deployerModel` | string | `glm-4.7` | Model for deployer agent |

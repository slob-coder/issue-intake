#!/bin/bash
set -euo pipefail
# poll.sh — 轮询新 Issue
# 用法: bash poll.sh
# stdout: JSON {"found": true, ...} 或 {"found": false}
# 副作用: 创建项目目录、生成 requirements.md 和 task.json、更新 intake-state、更新 Issue 标签和评论

source "$(dirname "$0")/common.sh"
load_config

# 1. Fetch new issues with "new-request" label
ISSUES_JSON=$(gh issue list --repo "$INTAKE_REPO" --label "new-request" --state open \
  --json number,title,body,createdAt,author --limit 10 2>/dev/null || echo "[]")

if [ "$ISSUES_JSON" = "[]" ] || [ -z "$ISSUES_JSON" ]; then
  jq --arg t "$(now_utc)" '.lastPollAt = $t' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
  echo '{"found": false}'
  exit 0
fi

# 2. Filter already-processed issues, take oldest
NEW_ISSUE=$(echo "$ISSUES_JSON" | jq --argjson processed "$(jq '.processedIssues | keys | map(tonumber)' "$INTAKE_STATE")" '
  [.[] | select(.number as $n | ($processed | index($n)) | not)]
  | sort_by(.createdAt)
  | first
')

if [ "$NEW_ISSUE" = "null" ] || [ -z "$NEW_ISSUE" ]; then
  jq --arg t "$(now_utc)" '.lastPollAt = $t' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
  echo '{"found": false}'
  exit 0
fi

# 3. Parse issue fields
ISSUE_NUMBER=$(echo "$NEW_ISSUE" | jq -r '.number')
ISSUE_TITLE=$(echo "$NEW_ISSUE" | jq -r '.title')
ISSUE_BODY=$(echo "$NEW_ISSUE" | jq -r '.body')
ISSUE_AUTHOR=$(echo "$NEW_ISSUE" | jq -r '.author.login')

# Derive project name from title
PROJECT_NAME=$(echo "$ISSUE_TITLE" | \
  sed 's/^\[Request\] *//i' | \
  tr '[:upper:]' '[:lower:]' | \
  sed 's/[^a-z0-9 -]//g' | \
  tr ' ' '-' | \
  sed 's/--*/-/g; s/^-//; s/-$//' | \
  cut -c1-50)

PROJECT_DIR="$PROJECTS_ROOT/$PROJECT_NAME"
mkdir -p "$PROJECT_DIR"

# 4. Parse structured Issue body sections
DESCRIPTION=$(echo "$ISSUE_BODY" | awk '/^### 📝 Description/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
REQUIREMENTS=$(echo "$ISSUE_BODY" | awk '/^### 📋 Requirements/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
CONSTRAINTS=$(echo "$ISSUE_BODY" | awk '/^### 🔧 Constraints/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
REFERENCES=$(echo "$ISSUE_BODY" | awk '/^### 📎 References/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
LICENSE_CHOICE=$(echo "$ISSUE_BODY" | awk '/^### 📄 License/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//' | head -1)

# Default license
if [ -z "$LICENSE_CHOICE" ] || [ "$LICENSE_CHOICE" = "_No response_" ]; then
  LICENSE_CHOICE="$DEFAULT_LICENSE"
fi

# 5. Generate requirements.md
NOW=$(now_utc)
cat > "$PROJECT_DIR/requirements.md" << REQEOF
# 需求说明书：$ISSUE_TITLE

> 来源：GitHub Issue #$ISSUE_NUMBER ($INTAKE_REPO)
> 提交者：@$ISSUE_AUTHOR
> 日期：$NOW

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

# 6. Generate task.json
cat > "$TASK_JSON" << TASKEOF
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

# 7. Update intake-state.json
jq --arg n "$ISSUE_NUMBER" --arg p "$PROJECT_NAME" --arg t "$NOW" '
  .activeIssue = ($n | tonumber) |
  .processedIssues[$n] = {
    "project": $p,
    "status": "pending",
    "createdAt": $t,
    "completedAt": null
  } |
  .lastPollAt = $t
' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"

# 8. Update Issue labels & post comment via interact.sh
bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$INTAKE_REPO" "new-request" "designing" >/dev/null

COMMENT_FILE=$(mktemp)
trap 'rm -f "$COMMENT_FILE"' EXIT
cat > "$COMMENT_FILE" << COMMENTEOF
🎨 **设计中...**

我们的 AI 设计师正在分析您的需求，稍后将提供技术方案供您确认。

> 项目名称：\`$PROJECT_NAME\`
COMMENTEOF

bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$INTAKE_REPO" "$COMMENT_FILE" >/dev/null

# 9. Output result
echo "{\"found\": true, \"issueNumber\": $ISSUE_NUMBER, \"project\": \"$PROJECT_NAME\", \"title\": $(echo "$ISSUE_TITLE" | jq -Rs '.')}"

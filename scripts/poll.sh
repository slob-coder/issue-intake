#!/bin/bash
set -euo pipefail
# poll.sh — 轮询新 Issue + 项目完整初始化
# 用法: bash poll.sh
# stdout: JSON {"found": true, ...} 或 {"found": false}
# 副作用: 创建项目目录(含子目录模板)、创建 GitHub 仓库、clone 仓库、
#         生成 requirements.md / environment.md / task.json、更新 intake-state、更新 Issue 标签和评论

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

# 4. Create project directory structure (analyst template)
mkdir -p "$PROJECT_DIR"/{repo,tasks,reviews,test-reports,release-notes}
log "Created project directory structure: $PROJECT_DIR"

# 5. Parse structured Issue body sections
DESCRIPTION=$(echo "$ISSUE_BODY" | awk '/^### 📝 Description/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
REQUIREMENTS=$(echo "$ISSUE_BODY" | awk '/^### 📋 Requirements/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
CONSTRAINTS=$(echo "$ISSUE_BODY" | awk '/^### 🔧 Constraints/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
REFERENCES=$(echo "$ISSUE_BODY" | awk '/^### 📎 References/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//')
LICENSE_CHOICE=$(echo "$ISSUE_BODY" | awk '/^### 📄 License/{flag=1; next} /^### /{flag=0} flag' | sed '/^$/d; s/^_No response_$//' | head -1)

# Default license
if [ -z "$LICENSE_CHOICE" ] || [ "$LICENSE_CHOICE" = "_No response_" ]; then
  LICENSE_CHOICE="$DEFAULT_LICENSE"
fi

# 6. Detect tech stack from constraints/description
DETECTED_LANG=""
DETECTED_PKG_MGR=""
DETECTED_BUILD=""
DETECTED_TEST=""

# Simple detection from constraints text
CONSTRAINTS_LOWER=$(echo "${CONSTRAINTS:-}" "${DESCRIPTION:-}" | tr '[:upper:]' '[:lower:]')
if echo "$CONSTRAINTS_LOWER" | grep -qE 'python|django|flask|fastapi'; then
  DETECTED_LANG="Python"
  DETECTED_PKG_MGR="pip"
  DETECTED_BUILD="python setup.py build"
  DETECTED_TEST="pytest"
elif echo "$CONSTRAINTS_LOWER" | grep -qE 'rust|cargo'; then
  DETECTED_LANG="Rust"
  DETECTED_PKG_MGR="cargo"
  DETECTED_BUILD="cargo build"
  DETECTED_TEST="cargo test"
elif echo "$CONSTRAINTS_LOWER" | grep -qE 'golang|go '; then
  DETECTED_LANG="Go"
  DETECTED_PKG_MGR="go mod"
  DETECTED_BUILD="go build ./..."
  DETECTED_TEST="go test ./..."
else
  # Default to Node.js/TypeScript
  DETECTED_LANG="Node.js / TypeScript"
  DETECTED_PKG_MGR="npm"
  DETECTED_BUILD="npm run build"
  DETECTED_TEST="npm test"
fi

NOW=$(now_utc)

# 7. Create delivery repo on GitHub
DELIVERY_REPO_NAME="$PROJECT_NAME"
DELIVERY_REPO_FULL="$DELIVERY_ORG/$DELIVERY_REPO_NAME"

if ! gh repo view "$DELIVERY_REPO_FULL" &>/dev/null; then
  CLEAN_TITLE=$(echo "$ISSUE_TITLE" | sed 's/^\[Request\] *//')
  if gh repo create "$DELIVERY_REPO_FULL" --public \
    --description "$CLEAN_TITLE" \
    --license "${LICENSE_CHOICE,,}" 2>&1 >/dev/null; then
    log "Created delivery repo: $DELIVERY_REPO_FULL"
    sleep 2  # Wait for GitHub to propagate
  else
    log "Warning: Failed to create delivery repo, will retry later"
    DELIVERY_REPO_FULL=""
  fi
else
  log "Delivery repo already exists: $DELIVERY_REPO_FULL"
fi

# 8. Clone delivery repo
if [ -n "$DELIVERY_REPO_FULL" ] && [ ! -d "$PROJECT_DIR/repo/.git" ]; then
  if gh repo clone "$DELIVERY_REPO_FULL" "$PROJECT_DIR/repo" 2>/dev/null; then
    log "Cloned $DELIVERY_REPO_FULL to $PROJECT_DIR/repo/"
  else
    log "Warning: Failed to clone, will init empty repo"
    cd "$PROJECT_DIR/repo"
    git init
    git remote add origin "https://github.com/$DELIVERY_REPO_FULL.git" 2>/dev/null || true
    cd - >/dev/null
  fi
fi

# 9. Detect default branch
DEFAULT_BRANCH="main"
if [ -d "$PROJECT_DIR/repo/.git" ]; then
  DETECTED_BRANCH=$(cd "$PROJECT_DIR/repo" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")
  [ -n "$DETECTED_BRANCH" ] && DEFAULT_BRANCH="$DETECTED_BRANCH"
fi

# 10. Generate requirements.md
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

# 11. Generate/update environment.md
ENV_FILE="$HOME/.openclaw/shared/environment.md"
if [ ! -f "$ENV_FILE" ]; then
  echo "# 项目环境信息" > "$ENV_FILE"
  echo "" >> "$ENV_FILE"
fi

# Append project section (or replace if exists)
if grep -q "^## $PROJECT_NAME$" "$ENV_FILE" 2>/dev/null; then
  # Project section already exists, update it using sed
  # For simplicity, just log and skip (analyst can update later)
  log "Environment section for $PROJECT_NAME already exists"
else
  cat >> "$ENV_FILE" << ENVEOF

## $PROJECT_NAME
- **仓库路径**: $PROJECT_DIR/repo/
- **GitHub URL**: https://github.com/$DELIVERY_REPO_FULL
- **默认分支**: $DEFAULT_BRANCH
- **语言/技术栈**: $DETECTED_LANG
- **包管理器**: $DETECTED_PKG_MGR
- **构建命令**: $DETECTED_BUILD
- **测试命令**: $DETECTED_TEST
- **依赖安装**: ${DETECTED_PKG_MGR} install
- **最后更新**: $NOW
ENVEOF
  log "Added environment section for $PROJECT_NAME"
fi

# 12. Generate project README.md
cat > "$PROJECT_DIR/README.md" << READMEEOF
# $PROJECT_NAME

- 创建时间: $NOW
- GitHub: https://github.com/$DELIVERY_REPO_FULL
- 来源: Issue #$ISSUE_NUMBER ($INTAKE_REPO)
- 描述: $(echo "$ISSUE_TITLE" | sed 's/^\[Request\] *//')
READMEEOF

# 13. Generate task.json
DELIVERY_REPO_JSON="null"
if [ -n "$DELIVERY_REPO_FULL" ]; then
  DELIVERY_REPO_JSON="\"$DELIVERY_REPO_FULL\""
fi

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
  "deliveryRepo": $DELIVERY_REPO_JSON,
  "retryCount": 0,
  "maxRetries": $MAX_RETRIES,
  "lastStatusChange": "$NOW",
  "designFeedback": null,
  "agentSpawned": false,
  "result": null,
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

# 14. Update intake-state.json
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

# 15. Update Issue labels & post comment via interact.sh
bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$INTAKE_REPO" "new-request" "designing" >/dev/null

COMMENT_FILE=$(mktemp)
trap 'rm -f "$COMMENT_FILE"' EXIT

REPO_LINE=""
if [ -n "$DELIVERY_REPO_FULL" ]; then
  REPO_LINE="> 交付仓库：[\`$DELIVERY_REPO_FULL\`](https://github.com/$DELIVERY_REPO_FULL)"
fi

cat > "$COMMENT_FILE" << COMMENTEOF
🎨 **设计中...**

我们的 AI 设计师正在分析您的需求，稍后将提供技术方案供您确认。

> 项目名称：\`$PROJECT_NAME\`
$REPO_LINE
COMMENTEOF

bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$INTAKE_REPO" "$COMMENT_FILE" >/dev/null

# 16. Output result
echo "{\"found\": true, \"issueNumber\": $ISSUE_NUMBER, \"project\": \"$PROJECT_NAME\", \"deliveryRepo\": \"$DELIVERY_REPO_FULL\", \"title\": $(echo "$ISSUE_TITLE" | jq -Rs '.')}"

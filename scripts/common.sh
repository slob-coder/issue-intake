#!/bin/bash
# common.sh — 公共函数库
# 被所有 issue-intake 脚本 source，提供路径常量、配置加载、辅助函数

# 路径常量
SKILL_DIR="$HOME/.openclaw/skills/issue-intake"
SCRIPTS_DIR="$SKILL_DIR/scripts"
INTAKE_STATE="$SKILL_DIR/.intake-state.json"
INTAKE_STATE_LEGACY="$HOME/.openclaw/shared/projects/.intake-state.json"
TASK_JSON="$HOME/.openclaw/shared/task.json"
PROJECTS_ROOT="$HOME/.openclaw/shared/projects"

# 确保 state 文件存在
ensure_state() {
  # 自动迁移：如果旧路径文件存在且新路径不存在，移动过来
  if [ -f "$INTAKE_STATE_LEGACY" ] && [ ! -f "$INTAKE_STATE" ]; then
    log "Migrating .intake-state.json from legacy path to $INTAKE_STATE"
    mv "$INTAKE_STATE_LEGACY" "$INTAKE_STATE"
  fi

  if [ ! -f "$INTAKE_STATE" ]; then
    mkdir -p "$(dirname "$INTAKE_STATE")"
    cat > "$INTAKE_STATE" << 'EOF'
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
EOF
  fi
}

# 读取配置
load_config() {
  ensure_state
  INTAKE_REPO="${INTAKE_REPO_OVERRIDE:-$(jq -r '.config.intakeRepo' "$INTAKE_STATE")}"
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
  ACTIVE_ISSUE=$(jq -r '.activeIssue // empty' "$INTAKE_STATE")

  # Auto-detect bot user if not configured
  if [ -z "$BOT_USER" ]; then
    BOT_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
    if [ -n "$BOT_USER" ]; then
      jq --arg u "$BOT_USER" '.config.botGithubUser = $u' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
    fi
  fi
}

# 加载 task.json（如果有 activeIssue）
load_task() {
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
    ISSUE_TITLE=$(jq -r '.title // empty' "$TASK_JSON")
    return 0
  fi
  return 1
}

# 日志输出（到 stderr）
log() {
  echo "[issue-intake] $*" >&2
}

# 计算时间差（小时）— 兼容 macOS (date -j) 和 Linux (date -d)
hours_since() {
  local timestamp="$1"
  local ts_epoch
  # Try macOS format first, then GNU/Linux
  ts_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%s" 2>/dev/null || \
             date -d "$timestamp" "+%s" 2>/dev/null || \
             echo "0")
  local now_epoch
  now_epoch=$(date -u "+%s")
  echo $(( (now_epoch - ts_epoch) / 3600 ))
}

# 当前 UTC 时间
now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# 更新 task.json 状态（带 history）
update_task_status() {
  local new_status="$1"
  local actor="$2"
  local note="${3:-}"

  local now
  now=$(now_utc)
  local old_status
  old_status=$(jq -r '.status' "$TASK_JSON")

  if [ -n "$note" ]; then
    jq --arg s "$new_status" --arg t "$now" --arg old "$old_status" --arg a "$actor" --arg n "$note" '
      .status = $s | .agentSpawned = false | .lastStatusChange = $t |
      .history += [{"timestamp": $t, "from": $old, "to": $s, "actor": $a, "note": $n}]
    ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
  else
    jq --arg s "$new_status" --arg t "$now" --arg old "$old_status" --arg a "$actor" '
      .status = $s | .agentSpawned = false | .lastStatusChange = $t |
      .history += [{"timestamp": $t, "from": $old, "to": $s, "actor": $a}]
    ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
  fi
}

# 更新 intake-state 中某 Issue 的状态
update_issue_state() {
  local issue_number="$1"
  local new_status="$2"

  jq --arg n "$issue_number" --arg s "$new_status" \
    '.processedIssues[$n].status = $s' \
    "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"
}

# 设置 agentSpawned = true 并更新 lastStatusChange
mark_agent_spawned() {
  local now
  now=$(now_utc)
  jq --arg t "$now" '
    .agentSpawned = true |
    .lastStatusChange = $t
  ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"
}

# 状态标签同步（通过 interact.sh）
sync_status_label() {
  local issue_number="$1"
  local repo="$2"
  local new_status="$3"

  bash "$SCRIPTS_DIR/interact.sh" sync-status "$issue_number" "$repo" "$new_status"
}

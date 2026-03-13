#!/bin/bash
set -euo pipefail
# check-feedback.sh — 检查 Issue 评论反馈（awaiting_approval 状态）
# 用法: bash check-feedback.sh
# stdout: JSON {"action": "approve|change|stale|none", ...}
# 副作用: approve/change/stale 时更新 task.json、intake-state、Issue 标签和评论

source "$(dirname "$0")/common.sh"
load_config
load_task

if [ -z "$ISSUE_NUMBER" ] || [ -z "$ISSUE_REPO" ]; then
  echo '{"action": "none", "error": "No issue number or repo"}'
  exit 0
fi

# 1. Get all comments on the issue
COMMENTS_JSON=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json comments --jq '.comments' 2>/dev/null || echo "[]")

# 2. Find last bot design comment timestamp
LAST_DESIGN_TIME=$(echo "$COMMENTS_JSON" | jq -r --arg bot "$BOT_USER" '
  [.[] | select(.author.login == $bot and (.body | contains("设计方案已完成")))] | last | .createdAt // empty
')

if [ -z "$LAST_DESIGN_TIME" ]; then
  LAST_DESIGN_TIME="$LAST_STATUS_CHANGE"
fi

# 3. Get Issue author
ISSUE_AUTHOR=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json author --jq '.author.login' 2>/dev/null || echo "")

# 4. Filter comments after design was posted, excluding bot
FEEDBACK_COMMENTS=$(echo "$COMMENTS_JSON" | jq --arg since "$LAST_DESIGN_TIME" --arg bot "$BOT_USER" '
  [.[] | select(.createdAt > $since and .author.login != $bot)]
')

FEEDBACK_COUNT=$(echo "$FEEDBACK_COMMENTS" | jq 'length')

if [ "$FEEDBACK_COUNT" -gt 0 ]; then
  # Check each comment for authorized users
  for i in $(seq 0 $((FEEDBACK_COUNT - 1))); do
    COMMENTER=$(echo "$FEEDBACK_COMMENTS" | jq -r ".[$i].author.login")
    COMMENT_BODY_RAW=$(echo "$FEEDBACK_COMMENTS" | jq -r ".[$i].body")

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

    # Check if it's an approval
    if echo "$COMMENT_BODY_RAW" | grep -qiE '^\s*(👍|LGTM|approved|确认|通过|OK|没问题|approve|looks good)\s*$'; then
      # APPROVED
      log "User approved the design"

      NOW=$(now_utc)
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

      update_issue_state "$ISSUE_NUMBER" "in_progress"

      # Update labels
      bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$ISSUE_REPO" "awaiting-feedback" "in-progress" >/dev/null

      # Post status comment
      COMMENT_FILE=$(mktemp)
      trap 'rm -f "$COMMENT_FILE"' EXIT
      cat > "$COMMENT_FILE" << 'APPROVEEOF'
💻 **开发中...**

方案已确认，AI 工程师正在编码实现。
APPROVEEOF
      bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$ISSUE_REPO" "$COMMENT_FILE" >/dev/null

      echo '{"action": "approve"}'
      exit 0
    else
      # CHANGE REQUEST
      log "User requested changes"

      # Save feedback to file
      echo "$COMMENT_BODY_RAW" > "$PROJECT_DIR/feedback.md"

      NOW=$(now_utc)
      jq --arg t "$NOW" --arg fb "$COMMENT_BODY_RAW" '
        .status = "pending" |
        .agentSpawned = false |
        .retryCount = 0 |
        .lastStatusChange = $t |
        .designFeedback = $fb |
        .history += [
          {
            "timestamp": $t,
            "from": "awaiting_approval",
            "to": "pending",
            "actor": "issue-intake",
            "note": "User requested design changes"
          }
        ]
      ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

      update_issue_state "$ISSUE_NUMBER" "pending"

      # Update labels
      bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$ISSUE_REPO" "awaiting-feedback" "designing" >/dev/null

      # Post status comment
      COMMENT_FILE=$(mktemp)
      trap 'rm -f "$COMMENT_FILE"' EXIT
      cat > "$COMMENT_FILE" << 'CHANGEEOF'
🎨 **收到修改意见，重新设计中...**

感谢您的反馈！我们的 AI 设计师正在根据您的意见调整方案。
CHANGEEOF
      bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$ISSUE_REPO" "$COMMENT_FILE" >/dev/null

      echo "{\"action\": \"change\", \"feedback\": $(echo "$COMMENT_BODY_RAW" | jq -Rs '.')}"
      exit 0
    fi
  done

  # No authorized feedback found
  HOURS_WAITING=$(hours_since "$LAST_DESIGN_TIME")
  echo "{\"action\": \"none\", \"hoursWaiting\": $HOURS_WAITING}"
  exit 0
fi

# No new comments — check stale timeout
HOURS_WAITING=$(hours_since "$LAST_DESIGN_TIME")

if [ "$HOURS_WAITING" -ge "$STALE_TIMEOUT" ]; then
  log "Stale timeout (${HOURS_WAITING}h). Closing issue."

  # Close as stale
  COMMENT_FILE=$(mktemp)
  trap 'rm -f "$COMMENT_FILE"' EXIT
  cat > "$COMMENT_FILE" << 'STALEEOF'
⏰ **自动关闭**

72 小时未收到回复，此需求已自动关闭。

如仍需要，请重新打开此 Issue 或提交新的请求。
STALEEOF

  bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$ISSUE_REPO" "$COMMENT_FILE" >/dev/null
  bash "$SCRIPTS_DIR/interact.sh" close "$ISSUE_NUMBER" "$ISSUE_REPO" >/dev/null
  bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$ISSUE_REPO" "awaiting-feedback" "stale" >/dev/null

  # Clear active issue
  NOW=$(now_utc)
  jq --arg n "$ISSUE_NUMBER" --arg t "$NOW" '
    .activeIssue = null |
    .processedIssues[$n].status = "stale" |
    .processedIssues[$n].completedAt = $t
  ' "$INTAKE_STATE" > "${INTAKE_STATE}.tmp" && mv "${INTAKE_STATE}.tmp" "$INTAKE_STATE"

  echo "{\"action\": \"stale\", \"hoursWaiting\": $HOURS_WAITING}"
  exit 0
fi

echo "{\"action\": \"none\", \"hoursWaiting\": $HOURS_WAITING}"

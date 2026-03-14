#!/bin/bash
set -euo pipefail
# bridge-status.sh — 检查 agent 是否已完成并桥接状态
# 读取 task.json 的 result.status，如果与顶层 .status 不一致则更新
# stdout: JSON {"changed": true/false, "from": "...", "to": "..."}

source "$(dirname "$0")/common.sh"
load_config

if ! load_task; then
  echo '{"changed": false, "error": "no task"}'
  exit 0
fi

# Read result.status (what the agent writes)
RESULT_STATUS=$(jq -r '.result.status // empty' "$TASK_JSON")

if [ -z "$RESULT_STATUS" ]; then
  echo '{"changed": false, "reason": "no result.status"}'
  exit 0
fi

# Map agent result.status to intake status
# Agent writes: designed, in_review, approved, changes_requested, tested, test_failed, released, in_progress
# Intake expects: pending, designed, awaiting_approval, in_progress, in_review, approved, tested, released
case "$RESULT_STATUS" in
  "designed")           NEW_STATUS="designed" ;;
  "in_review")          NEW_STATUS="in_review" ;;
  "approved")           NEW_STATUS="approved" ;;
  "changes_requested")  NEW_STATUS="in_progress" ;;  # reviewer rejected → back to coder
  "tested")             NEW_STATUS="tested" ;;
  "test_failed")        NEW_STATUS="in_progress" ;;  # tester failed → back to coder (fix task)
  "in_progress")        NEW_STATUS="in_progress" ;;
  "released")           NEW_STATUS="released" ;;
  *)
    echo "{\"changed\": false, \"reason\": \"unknown result.status: $RESULT_STATUS\"}"
    exit 0
    ;;
esac

# If already matches, no change needed
if [ "$TASK_STATUS" = "$NEW_STATUS" ]; then
  echo "{\"changed\": false, \"reason\": \"status already $NEW_STATUS\"}"
  exit 0
fi

# Update top-level status
OLD_STATUS="$TASK_STATUS"
update_task_status "$NEW_STATUS" "bridge-status" "Bridged from result.status=$RESULT_STATUS"

# Also update intake-state if we have an issue
if [ -n "$ISSUE_NUMBER" ]; then
  update_issue_state "$ISSUE_NUMBER" "$NEW_STATUS"
fi

echo "{\"changed\": true, \"from\": \"$OLD_STATUS\", \"to\": \"$NEW_STATUS\", \"resultStatus\": \"$RESULT_STATUS\"}"

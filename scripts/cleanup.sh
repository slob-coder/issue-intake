#!/bin/bash
set -euo pipefail
# cleanup.sh — 归档清理（released 状态后的收尾）
# 用法: bash cleanup.sh
# stdout: JSON {"ok": true, ...}
# 副作用: 更新 intake-state.json（activeIssue→null, processedIssues 标记完成）

source "$(dirname "$0")/common.sh"
load_config
load_task

NOW=$(now_utc)

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

echo "{\"ok\": true, \"project\": \"$TASK_PROJECT\", \"issueNumber\": ${ISSUE_NUMBER:-null}}"

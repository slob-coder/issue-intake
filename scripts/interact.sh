#!/bin/bash
set -euo pipefail
# interact.sh — Issue 交互：评论、标签更新、关闭
# 用法:
#   interact.sh comment  <issue_number> <repo> <body_file>
#   interact.sh label    <issue_number> <repo> <remove_csv> <add_csv>
#   interact.sh close    <issue_number> <repo>
#   interact.sh sync-status <issue_number> <repo> <new_status>
#
# stdout: JSON {"ok": true} 或 {"ok": false, "error": "..."}
# stderr: 日志

source "$(dirname "$0")/common.sh"

ACTION="${1:-}"
ISSUE_NUM="${2:-}"
REPO="${3:-}"

if [ -z "$ACTION" ] || [ -z "$ISSUE_NUM" ] || [ -z "$REPO" ]; then
  echo '{"ok": false, "error": "Usage: interact.sh <action> <issue_number> <repo> [args...]"}'
  exit 1
fi

case "$ACTION" in
  comment)
    BODY_FILE="${4:-}"
    if [ -z "$BODY_FILE" ] || [ ! -f "$BODY_FILE" ]; then
      echo '{"ok": false, "error": "comment: body file not found"}'
      exit 1
    fi
    if gh issue comment "$ISSUE_NUM" --repo "$REPO" --body-file "$BODY_FILE" >&2 2>&1; then
      echo '{"ok": true}'
    else
      echo '{"ok": false, "error": "gh issue comment failed"}'
      exit 1
    fi
    ;;

  label)
    REMOVE_CSV="${4:-}"
    ADD_CSV="${5:-}"

    # Remove labels (one by one, ignore errors for non-existent labels)
    if [ -n "$REMOVE_CSV" ] && [ "$REMOVE_CSV" != "-" ]; then
      IFS=',' read -ra REMOVE_LABELS <<< "$REMOVE_CSV"
      for lbl in "${REMOVE_LABELS[@]}"; do
        lbl=$(echo "$lbl" | xargs)  # trim whitespace
        [ -n "$lbl" ] && gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "$lbl" 2>/dev/null || true
      done
    fi

    # Add labels
    if [ -n "$ADD_CSV" ] && [ "$ADD_CSV" != "-" ]; then
      IFS=',' read -ra ADD_LABELS <<< "$ADD_CSV"
      for lbl in "${ADD_LABELS[@]}"; do
        lbl=$(echo "$lbl" | xargs)
        [ -n "$lbl" ] && gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "$lbl" 2>/dev/null || true
      done
    fi

    echo '{"ok": true}'
    ;;

  close)
    if gh issue close "$ISSUE_NUM" --repo "$REPO" >&2 2>&1; then
      echo '{"ok": true}'
    else
      echo '{"ok": false, "error": "gh issue close failed"}'
      exit 1
    fi
    ;;

  sync-status)
    NEW_STATUS="${4:-}"
    if [ -z "$NEW_STATUS" ]; then
      echo '{"ok": false, "error": "sync-status: missing new_status"}'
      exit 1
    fi

    # Remove all status labels
    for label in designing awaiting-feedback in-progress in-review testing releasing; do
      gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
    done

    # Add new status label
    case "$NEW_STATUS" in
      "pending")           gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "designing" 2>/dev/null || true ;;
      "designed")          gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "awaiting-feedback" 2>/dev/null || true ;;
      "awaiting_approval") ;; # Keep awaiting-feedback (already set by designed)
      "in_progress")       gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "in-progress" 2>/dev/null || true ;;
      "in_review")         gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "in-review" 2>/dev/null || true ;;
      "approved")          gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "testing" 2>/dev/null || true ;;
      "tested")            gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "releasing" 2>/dev/null || true ;;
      "released")          gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "completed" 2>/dev/null || true ;;
    esac

    echo '{"ok": true}'
    ;;

  *)
    echo "{\"ok\": false, \"error\": \"Unknown action: $ACTION\"}"
    exit 1
    ;;
esac

#!/bin/bash
set -euo pipefail
# dispatch.sh — 状态机主调度
# 用法: bash dispatch.sh
# stdout: JSON {"action": "...", ...}
# 副作用: 超时检测更新 task.json、designed 状态发布评论、released 状态交付通知

source "$(dirname "$0")/common.sh"
load_config

# No active issue → need to poll
if [ -z "$ACTIVE_ISSUE" ]; then
  echo '{"action": "poll"}'
  exit 0
fi

# Load task
if ! load_task; then
  echo '{"action": "error", "message": "task.json not found or no active issue"}'
  exit 0
fi

# --- Pre-check: Agent timeout detection ---
if [ "$AGENT_SPAWNED" = "true" ] && [ -n "$LAST_STATUS_CHANGE" ]; then
  HOURS_ELAPSED=$(hours_since "$LAST_STATUS_CHANGE")

  if [ "$HOURS_ELAPSED" -ge "$AGENT_TIMEOUT" ]; then
    log "Agent timeout detected (${HOURS_ELAPSED}h). Status: $TASK_STATUS"

    NEW_RETRY=$((RETRY_COUNT + 1))

    if [ "$NEW_RETRY" -gt "$MAX_RETRIES" ]; then
      # Escalate — too many retries
      log "Max retries ($MAX_RETRIES) exceeded. Escalating."

      local_now=$(now_utc)
      jq --arg t "$local_now" '
        .agentSpawned = false |
        .retryCount = (.retryCount + 1) |
        .lastStatusChange = $t
      ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

      if [ -n "$ISSUE_NUMBER" ] && [ "$TASK_SOURCE" = "github-issue" ]; then
        COMMENT_FILE=$(mktemp)
        trap 'rm -f "$COMMENT_FILE"' EXIT
        cat > "$COMMENT_FILE" << ESCALATEEOF
⚠️ **需要人工介入**

此需求在 \`$TASK_STATUS\` 阶段处理超时，已超过最大重试次数（$MAX_RETRIES 次）。

我们的团队会尽快查看。抱歉给您带来不便！
ESCALATEEOF
        bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$ISSUE_REPO" "-" "needs-help" >/dev/null
        bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$ISSUE_REPO" "$COMMENT_FILE" >/dev/null
      fi

      echo "{\"action\": \"escalate\", \"status\": \"$TASK_STATUS\", \"message\": \"Max retries exceeded\"}"
      exit 0
    fi

    # Reset agentSpawned for re-spawn
    local_now=$(now_utc)
    jq --arg t "$local_now" --argjson r "$NEW_RETRY" '
      .agentSpawned = false |
      .retryCount = $r |
      .lastStatusChange = $t
    ' "$TASK_JSON" > "${TASK_JSON}.tmp" && mv "${TASK_JSON}.tmp" "$TASK_JSON"

    AGENT_SPAWNED="false"
    RETRY_COUNT=$NEW_RETRY
    log "Retry $NEW_RETRY/$MAX_RETRIES — re-spawning agent for status: $TASK_STATUS"
  fi
fi

# --- Guard: agent already running ---
if [ "$AGENT_SPAWNED" = "true" ]; then
  HOURS_ELAPSED=$(hours_since "$LAST_STATUS_CHANGE")
  echo "{\"action\": \"wait\", \"status\": \"$TASK_STATUS\", \"message\": \"Agent running (${HOURS_ELAPSED}h/${AGENT_TIMEOUT}h)\"}"
  exit 0
fi

# --- Dispatch by status ---
case "$TASK_STATUS" in

  pending)
    # Build model field
    MODEL_FIELD=""
    if [ -n "$DESIGNER_MODEL" ]; then
      MODEL_FIELD=", \"model\": \"$DESIGNER_MODEL\""
    fi
    echo "{\"action\": \"spawn\", \"role\": \"designer\", \"status\": \"pending\", \"project\": \"$TASK_PROJECT\", \"projectDir\": \"$PROJECT_DIR\", \"retry\": $RETRY_COUNT${MODEL_FIELD}}"
    ;;

  designed)
    # Post design to Issue (deterministic, done in-script)
    if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
      DESIGN_FILE="$PROJECT_DIR/design.md"
      if [ ! -f "$DESIGN_FILE" ]; then
        echo '{"action": "error", "message": "design.md not found"}'
        exit 0
      fi

      DESIGN_CONTENT=$(cat "$DESIGN_FILE")

      # Approval hint based on approverMode
      case "$APPROVER_MODE" in
        "author")
          ISSUE_AUTHOR_LOGIN=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json author --jq '.author.login' 2>/dev/null || echo "unknown")
          APPROVAL_HINT="👤 **确认权限：** 仅 Issue 提交者 @${ISSUE_AUTHOR_LOGIN} 的回复视为有效确认。"
          ;;
        "allowlist")
          MENTIONS=$(echo "$APPROVERS" | sed 's/,/ @/g; s/^/@/')
          APPROVAL_HINT="👤 **确认权限：** 仅以下用户的回复视为有效确认：${MENTIONS}"
          ;;
        "any")
          APPROVAL_HINT="👤 **确认权限：** 任何用户均可确认。"
          ;;
        *)
          ISSUE_AUTHOR_LOGIN=$(gh issue view "$ISSUE_NUMBER" --repo "$ISSUE_REPO" --json author --jq '.author.login' 2>/dev/null || echo "unknown")
          APPROVAL_HINT="👤 **确认权限：** 仅 Issue 提交者 @${ISSUE_AUTHOR_LOGIN} 的回复视为有效确认。"
          ;;
      esac

      # Truncate if too long
      DESIGN_LENGTH=${#DESIGN_CONTENT}
      if [ "$DESIGN_LENGTH" -gt 50000 ]; then
        DESIGN_EXCERPT="${DESIGN_CONTENT:0:50000}

---
> ⚠️ 设计文档过长，已截断。完整版本请查看项目文件。"
      else
        DESIGN_EXCERPT="$DESIGN_CONTENT"
      fi

      # Write comment body to file
      COMMENT_FILE=$(mktemp)
      trap 'rm -f "$COMMENT_FILE"' EXIT
      cat > "$COMMENT_FILE" << DESIGNEOF
📋 **设计方案已完成！**

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

> ⏰ 72 小时内未回复将自动关闭此需求
DESIGNEOF

      bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$ISSUE_REPO" "$COMMENT_FILE" >/dev/null
      bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$ISSUE_REPO" "designing" "awaiting-feedback" >/dev/null
    fi

    # Update task.json → awaiting_approval
    update_task_status "awaiting_approval" "issue-intake"
    update_issue_state "$ISSUE_NUMBER" "awaiting_approval"

    echo "{\"action\": \"post_design\", \"done\": true, \"status\": \"awaiting_approval\", \"issueNumber\": $ISSUE_NUMBER}"
    ;;

  awaiting_approval)
    if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
      echo "{\"action\": \"check_feedback\", \"status\": \"awaiting_approval\", \"issueNumber\": $ISSUE_NUMBER, \"issueRepo\": \"$ISSUE_REPO\"}"
    else
      echo "{\"action\": \"skip\", \"status\": \"awaiting_approval\", \"message\": \"Manual task, handled by main agent\"}"
    fi
    ;;

  in_progress)
    MODEL_FIELD=""
    if [ -n "$CODER_MODEL" ]; then
      MODEL_FIELD=", \"model\": \"$CODER_MODEL\""
    fi
    echo "{\"action\": \"spawn\", \"role\": \"coder\", \"status\": \"in_progress\", \"project\": \"$TASK_PROJECT\", \"projectDir\": \"$PROJECT_DIR\", \"retry\": $RETRY_COUNT${MODEL_FIELD}}"
    ;;

  in_review)
    MODEL_FIELD=""
    if [ -n "$REVIEWER_MODEL" ]; then
      MODEL_FIELD=", \"model\": \"$REVIEWER_MODEL\""
    fi
    echo "{\"action\": \"spawn\", \"role\": \"reviewer\", \"status\": \"in_review\", \"project\": \"$TASK_PROJECT\", \"projectDir\": \"$PROJECT_DIR\", \"retry\": $RETRY_COUNT${MODEL_FIELD}}"
    ;;

  approved)
    MODEL_FIELD=""
    if [ -n "$TESTER_MODEL" ]; then
      MODEL_FIELD=", \"model\": \"$TESTER_MODEL\""
    fi
    echo "{\"action\": \"spawn\", \"role\": \"tester\", \"status\": \"approved\", \"project\": \"$TASK_PROJECT\", \"projectDir\": \"$PROJECT_DIR\", \"retry\": $RETRY_COUNT${MODEL_FIELD}}"
    ;;

  tested)
    MODEL_FIELD=""
    if [ -n "$DEPLOYER_MODEL" ]; then
      MODEL_FIELD=", \"model\": \"$DEPLOYER_MODEL\""
    fi
    echo "{\"action\": \"spawn\", \"role\": \"deployer\", \"status\": \"tested\", \"project\": \"$TASK_PROJECT\", \"projectDir\": \"$PROJECT_DIR\", \"retry\": $RETRY_COUNT${MODEL_FIELD}}"
    ;;

  released)
    # Post release notification & close issue (deterministic, done in-script)
    if [ "$TASK_SOURCE" = "github-issue" ] && [ -n "$ISSUE_NUMBER" ]; then
      DELIVERY_REPO=$(jq -r '.deliveryRepo // empty' "$TASK_JSON")
      RELEASE_URL="https://github.com/$DELIVERY_REPO/releases/tag/v1.0.0"

      # Try to get actual release URL
      ACTUAL_RELEASE=$(gh release view --repo "$DELIVERY_REPO" --json url --jq '.url' 2>/dev/null || echo "")
      [ -n "$ACTUAL_RELEASE" ] && RELEASE_URL="$ACTUAL_RELEASE"

      COMMENT_FILE=$(mktemp)
      trap 'rm -f "$COMMENT_FILE"' EXIT
      cat > "$COMMENT_FILE" << RELEASEEOF
🚀 **已发布！**

您的需求已完成交付！

📦 **仓库地址：** https://github.com/$DELIVERY_REPO
🏷️ **Release 地址：** $RELEASE_URL

感谢使用 OpenClaw！如有问题欢迎新建 Issue。
RELEASEEOF

      bash "$SCRIPTS_DIR/interact.sh" comment "$ISSUE_NUMBER" "$ISSUE_REPO" "$COMMENT_FILE" >/dev/null
      bash "$SCRIPTS_DIR/interact.sh" label "$ISSUE_NUMBER" "$ISSUE_REPO" "releasing" "completed" >/dev/null
      bash "$SCRIPTS_DIR/interact.sh" close "$ISSUE_NUMBER" "$ISSUE_REPO" >/dev/null
    fi

    echo "{\"action\": \"finalize\", \"status\": \"released\", \"issueNumber\": ${ISSUE_NUMBER:-null}, \"deliveryRepo\": \"${DELIVERY_REPO:-}\"}"
    ;;

  *)
    echo "{\"action\": \"error\", \"message\": \"Unknown task status: $TASK_STATUS\"}"
    ;;
esac

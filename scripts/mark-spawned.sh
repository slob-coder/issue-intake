#!/bin/bash
set -euo pipefail
# mark-spawned.sh — 标记 agent 已启动
# stdout: JSON {"ok": true}

source "$(dirname "$0")/common.sh"
load_config

if [ ! -f "$TASK_JSON" ]; then
  echo '{"ok": false, "error": "task.json not found"}'
  exit 1
fi

mark_agent_spawned
echo '{"ok": true}'

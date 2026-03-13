#!/bin/bash
set -euo pipefail
# init.sh — 仓库初始化（--init 模式）
# 用法: INTAKE_REPO_OVERRIDE="owner/repo" bash init.sh
# stdout: JSON {"ok": true, ...} 或 {"ok": false, "error": "..."}

source "$(dirname "$0")/common.sh"
load_config

# 1. Create repository if not exists
if ! gh repo view "$INTAKE_REPO" &>/dev/null; then
  if gh repo create "$INTAKE_REPO" --public \
    --description "🦀 Submit development requests — our AI team builds them for you!" \
    --license MIT >&2 2>&1; then
    log "Created repository: $INTAKE_REPO"
  else
    echo "{\"ok\": false, \"error\": \"Failed to create repository $INTAKE_REPO\"}"
    exit 1
  fi
else
  log "Repository $INTAKE_REPO already exists"
fi

# 2. Clone and push templates
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

gh repo clone "$INTAKE_REPO" "$WORK_DIR" 2>/dev/null || \
  (cd "$WORK_DIR" && git init && git remote add origin "https://github.com/$INTAKE_REPO.git") >&2

cd "$WORK_DIR"

# Create directory structure
mkdir -p .github/ISSUE_TEMPLATE

# Copy templates
cp "$SCRIPTS_DIR/templates/feature-request.yml" .github/ISSUE_TEMPLATE/feature-request.yml
cp "$SCRIPTS_DIR/templates/README.md" README.md
cp "$SCRIPTS_DIR/templates/CONTRIBUTING.md" CONTRIBUTING.md

# Copy LICENSE (if not already present)
if [ ! -f LICENSE ]; then
  cp "$SCRIPTS_DIR/templates/LICENSE" LICENSE
fi

# Commit and push
git add -A
if git diff --cached --quiet; then
  log "No changes to push"
else
  git commit -m "chore: initialize intake repository with templates" >&2
  (git push -u origin main 2>/dev/null || git push -u origin master) >&2
  log "Templates pushed to $INTAKE_REPO"
fi

# 3. Initialize labels
bash "$SCRIPTS_DIR/init-labels.sh" "$INTAKE_REPO" >&2
log "Labels initialized"

# 4. Output result
echo "{\"ok\": true, \"repo\": \"$INTAKE_REPO\", \"message\": \"Repository initialized\"}"

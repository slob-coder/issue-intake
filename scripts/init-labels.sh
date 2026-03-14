#!/bin/bash
# init-labels.sh — Initialize GitHub Issue labels for the intake repository
# Usage: ./init-labels.sh [owner/repo]
#
# Creates or updates all status labels used by the issue-intake system.
# Requires: gh CLI (authenticated)
# Compatible with bash 3.2+ (macOS default)

set -euo pipefail

REPO="${1:-openclaw/community-requests}"

echo "🏷️  Initializing labels for $REPO..."

# Label definitions: "name|color|description"
LABELS=(
  "new-request|0E8A16|New feature request submitted"
  "designing|1D76DB|AI designer is working on the technical plan"
  "awaiting-feedback|FBCA04|Design ready, waiting for user confirmation"
  "in-progress|5319E7|Development in progress"
  "in-review|D93F0B|Code review in progress"
  "testing|BFD4F2|Running automated tests"
  "releasing|006B75|Packaging and releasing"
  "completed|0E8A16|Request completed and delivered"
  "stale|CCCCCC|No response, auto-closed"
  "needs-help|B60205|Requires manual intervention"
)

CREATED=0
FAILED=0

for entry in "${LABELS[@]}"; do
  IFS='|' read -r label color desc <<< "$entry"
  if gh label create "$label" --repo "$REPO" --color "$color" --description "$desc" --force 2>/dev/null; then
    echo "  ✅ $label (#$color)"
    CREATED=$((CREATED + 1))
  else
    echo "  ❌ $label — failed"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Done! $CREATED labels created/updated, $FAILED failed."

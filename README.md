# 🦀 issue-intake

> OpenClaw Skill — Turn GitHub Issues into fully automated development requests

## What is this?

An OpenClaw Skill that bridges GitHub Issues with an AI development team. Users submit feature requests via Issues, and the system automatically designs, builds, reviews, tests, and delivers the project.

## How it works

```
User opens Issue → AI Designer creates plan → User approves → AI Coder builds →
AI Reviewer checks → AI Tester validates → AI Deployer releases → User gets Release
```

## Pipeline Stages

| Stage | Description |
|-------|-------------|
| `pending` | New request, queued for design |
| `designed` | Technical plan ready |
| `awaiting_approval` | Waiting for user confirmation |
| `in_progress` | Development underway |
| `in_review` | Code review |
| `approved` | Review passed |
| `tested` | All tests passed |
| `released` | Delivered via GitHub Release |

## Quick Start

```bash
# Install: copy to OpenClaw skills directory
cp -r . ~/.openclaw/skills/issue-intake/

# Initialize the intake repository
/issue-intake --init

# Set up automatic polling (every 5 minutes)
openclaw cron add --schedule "*/5 * * * *" --command "/issue-intake --cron" --name "issue-intake-poll"
```

See [DEPLOYMENT.md](./DEPLOYMENT.md) for detailed setup instructions.

## Features

- 🎯 Structured Issue Template for clear requirements
- 🤖 Fully automated 8-stage pipeline
- 💬 User interaction via Issue comments
- 🔐 Configurable approval modes (author/allowlist/any)
- 🔄 Auto-retry with escalation (max 3 retries → needs-help)
- ⏰ 72h stale timeout protection
- 📦 GitHub Release delivery with DEPLOYMENT.md
- ⚡ Cron-based polling, no webhook needed

## Requirements

- [OpenClaw](https://github.com/openclaw/openclaw) with agents team configured
- gh CLI 2.x (authenticated)
- jq 1.6+
- git 2.x

## License

MIT

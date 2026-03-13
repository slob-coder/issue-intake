# DEPLOYMENT.md — issue-intake Skill 部署说明

## 环境要求

| 依赖 | 最低版本 | 说明 |
|------|---------|------|
| macOS / Linux | — | Windows 未测试 |
| gh CLI | 2.x | 需已认证，token 需含 `repo` scope |
| jq | 1.6+ | JSON 处理 |
| git | 2.x | 代码推送 |
| OpenClaw | — | 已安装并配置 agents 团队（designer/coder/reviewer/tester/deployer）|

## 安装步骤

### Step 1：确认 Skill 文件就位

```bash
ls ~/.openclaw/skills/issue-intake/
# 应看到：SKILL.md, scripts/
```

如果文件不在，从仓库克隆：

```bash
gh repo clone slob/issue-intake ~/.openclaw/skills/issue-intake
```

### Step 2：初始化 GitHub 仓库

```bash
/issue-intake --init
```

这会：
- 创建公开仓库（默认 `openclaw/community-requests`，可通过配置修改）
- 推送 Issue Template、README、CONTRIBUTING、LICENSE
- 创建 10 个状态标签

### Step 3：设置 Cron 轮询

```bash
openclaw cron add --schedule "*/5 * * * *" --command "/issue-intake --cron" --name "issue-intake-poll"
```

每 5 分钟自动检查新 Issue 并推进状态机。

## 配置说明

编辑 `~/.openclaw/shared/projects/.intake-state.json` 中的 `config` 区：

```json
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
  }
}
```

### 关键配置项

| 配置 | 说明 |
|------|------|
| `intakeRepo` | 需求收集仓库地址（`owner/repo`）|
| `deliveryOrg` | 交付仓库所属 org/用户 |
| `approverMode` | 设计方案确认人：`author`（Issue 提交者）、`allowlist`（指定用户列表）、`any`（任何人）|
| `approvers` | `allowlist` 模式下的授权用户列表 |
| `botGithubUser` | bot 的 GitHub 用户名（留空自动检测）|
| `*Model` | 各 agent 使用的模型（留空用默认）|

## 启动命令

| 命令 | 说明 |
|------|------|
| `/issue-intake` | 交互模式，轮询并处理 |
| `/issue-intake --cron` | Cron 模式，执行一个周期后退出 |
| `/issue-intake --init` | 初始化仓库和标签 |
| `/issue-intake --repo owner/repo` | 覆盖 intake 仓库地址 |

## 验证方法

### 1. 确认仓库存在
```bash
gh repo view openclaw/community-requests
```

### 2. 确认标签已创建
```bash
gh label list --repo openclaw/community-requests
# 应看到 10 个标签：new-request, designing, awaiting-feedback, ...
```

### 3. 端到端测试
1. 在 intake 仓库提交一个测试 Issue（使用 Feature Request 模板）
2. 运行 `/issue-intake`（或等 cron 触发）
3. 观察 Issue 上的评论和标签变化
4. 确认 designer 被触发并产出设计方案

## 常见问题

### gh 认证失败
```bash
gh auth login
gh auth status  # 确认 token scope 包含 repo
```

### 仓库已存在
`--init` 会跳过已有仓库，只推送模板文件（如有变更）和初始化标签。

### Cron 不执行
```bash
openclaw cron list                    # 确认 cron 已注册
openclaw cron logs --name issue-intake-poll  # 查看执行日志
/issue-intake --cron                 # 手动执行一次验证
```

### Agent 超时
系统会自动重试最多 3 次。如果超过重试次数，Issue 会被标记 `needs-help`，需要人工查看 `task.json` 和 agent 日志。

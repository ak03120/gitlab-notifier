# gitlab-notifier

GitLabのコメント（Issue / Merge Request）をトリガーに通知するCI/CDジョブです。

## CI設定に必要な変数

GitLab CI/CDの **Settings > CI/CD > Variables** に以下を登録してください。

| 変数名 | 説明 | 必須 |
| --- | --- | --- |
| `SLACK_BOT_TOKEN` | Slack Bot OAuthトークン（`xoxb-` から始まる文字列） | ✅ |
| `GITLAB_API_TOKEN` | GitLab Personal Access Token（`read_api` スコープ以上） | ✅ |

## 対応するWebhookイベント

| noteable_type | 説明 |
| --- | --- |
| `Issue` | Issueへのコメント |
| `MergeRequest` | Merge Requestへのコメント |

## Slackに必要な権限

| スコープ | 用途 |
| --- | --- |
| `chat:write` | DMの送信 |
| `users:read.email` | メールアドレスからユーザーを検索 |

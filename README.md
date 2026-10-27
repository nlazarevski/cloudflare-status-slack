# Cloudflare status to Slack

A GitHub Actions workflow that checks https://www.cloudflarestatus.com every 5 minutes and posts to a Slack channel when:

- the overall status changes
- an incident gets a new update (investigating / identified / monitoring / resolved)

## Setup

1. In Slack, create an incoming webhook for the channel (api.slack.com/apps → your app → Incoming Webhooks).
2. In this repo: **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `SLACK_WEBHOOK_URL`
   - Value: the webhook URL
3. **Actions** tab → enable workflows if asked → **Cloudflare status to Slack** → **Run workflow**.

The first run only records the current state and posts nothing. After that, each run posts what changed since the previous one.

## Options

Edit the `run:` line in `.github/workflows/cloudflare-status.yml`:

- `-Components 'Dashboard','API','*Workers*'` to also alert on specific component changes
- `-IncludeMaintenance` to also post scheduled maintenance updates
- `-StatusPage https://status.example.com` for any other Atlassian Statuspage site

For a private repo on a free account, change the cron to `'*/30 * * * *'` to stay within the
2,000 free Actions minutes a month (the keep-alive step isn't needed there, but is harmless).

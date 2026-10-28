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

## Filters

Like the status page's own "subscribe to components" option, you can limit which incidents get
posted. Set these under **Settings → Secrets and variables → Actions → Variables** (all optional):

| Variable | Example | Effect |
|---|---|---|
| `CF_CATEGORIES` | `DNS*;Dashboard;North America` | Only incidents affecting a matching component **or** group. `*` wildcards; separate with `;` or new lines (names contain commas). |
| `CF_MIN_IMPACT` | `minor` | Skip incidents below this impact: `none` (default), `minor`, `major`, `critical`. |
| `CF_SKIP_UNTAGGED` | `true` | With `CF_CATEGORIES`, also drop incidents that list no components (otherwise they're posted, since they may affect anything). |
| `CF_SKIP_OVERALL_STATUS` | `true` | Don't post overall status changes ("Partial System Outage" etc.). |

Groups on cloudflarestatus.com: `Cloudflare Sites and Services` (all products) and the regions
`Africa`, `Asia`, `Europe`, `Latin America & the Caribbean`, `Middle East`, `North America`, `Oceania`
(individual data centers). Changing a filter never replays old updates.

## Options

Edit the `run:` line in `.github/workflows/cloudflare-status.yml`:

- `-Components 'Dashboard','API','*Workers*'` to also alert on specific component changes
- `-IncludeMaintenance` to also post scheduled maintenance updates
- `-StatusPage https://status.example.com` for any other Atlassian Statuspage site

For a private repo on a free account, change the cron to `'*/30 * * * *'` to stay within the
2,000 free Actions minutes a month (the keep-alive step isn't needed there, but is harmless).

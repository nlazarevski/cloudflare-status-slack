<#
.SYNOPSIS
  Polls the Cloudflare status page (Atlassian Statuspage API) and posts changes to Slack.

.DESCRIPTION
  Run it on a schedule (e.g. every 5 minutes). Each run compares the live status with the
  state saved from the previous run and posts to a Slack incoming webhook when:
    - the overall status changes (e.g. "All Systems Operational" -> "Partial System Outage")
    - an incident gets a new update (investigating / identified / monitoring / resolved ...)
    - optionally, scheduled maintenance gets a new update (-IncludeMaintenance)
    - optionally, a watched component changes status (-Components "Dashboard","DNS*")

  Like the status page's own subscription options, incident posts can be limited to the
  components or groups you care about (-Categories) and to a minimum impact (-MinImpact).
  Each of these can also come from an environment variable (CF_CATEGORIES, CF_MIN_IMPACT,
  CF_SKIP_UNTAGGED, CF_SKIP_OVERALL_STATUS), which is how the GitHub workflow passes them.

  The first run only records the current state and posts nothing, so you don't get flooded
  with the last 50 incidents.

.EXAMPLE
  $env:SLACK_WEBHOOK_URL = 'https://hooks.slack.com/services/XXX/YYY/ZZZ'
  .\cloudflare-status-to-slack.ps1

.EXAMPLE
  .\cloudflare-status-to-slack.ps1 -Components 'Dashboard','API','*Workers*' -DryRun

.EXAMPLE
  # Only incidents touching these services or the North America region, minor impact or worse
  .\cloudflare-status-to-slack.ps1 -Categories 'DNS*','Dashboard','North America' -MinImpact minor
#>
param(
    [string]   $WebhookUrl = $env:SLACK_WEBHOOK_URL,
    [string]   $StatusPage = 'https://www.cloudflarestatus.com',
    [string[]] $Components = @(),           # wildcard names to watch; empty = none (Cloudflare lists ~480)
    # Wildcard component or group names; an incident is posted if it affects any of them.
    # Empty = all incidents. Env var form is separated by ';' or new lines (names contain commas).
    [string[]] $Categories = @(($env:CF_CATEGORIES -split '[;\r\n]') | ForEach-Object { $_.Trim() } | Where-Object { $_ }),
    [ValidateSet('none', 'minor', 'major', 'critical')]
    [string]   $MinImpact = $(if ($env:CF_MIN_IMPACT) { $env:CF_MIN_IMPACT } else { 'none' }),
    [switch]   $SkipUntagged = ($env:CF_SKIP_UNTAGGED -eq 'true'),            # with -Categories: drop incidents that list no components
    [switch]   $SkipOverallStatus = ($env:CF_SKIP_OVERALL_STATUS -eq 'true'), # don't post overall status changes
    [switch]   $IncludeMaintenance,
    # Small header on every post, so it stands apart from other alerts in a shared channel
    [string]   $Label = $(if ($env:CF_SLACK_LABEL) { $env:CF_SLACK_LABEL } else { ':cloud: *Cloudflare Status*' }),
    [string]   $StateFile  = (Join-Path $PSScriptRoot 'cloudflare-status-state.json'),
    [switch]   $DryRun,                     # print messages instead of posting
    [switch]   $TestPost                    # also post the latest update of the newest incident, to preview the format
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $DryRun -and -not $WebhookUrl) {
    throw 'No Slack webhook. Pass -WebhookUrl or set SLACK_WEBHOOK_URL (or use -DryRun).'
}

function Get-Api($path) { Invoke-RestMethod -Uri "$StatusPage/api/v2/$path" -TimeoutSec 30 }

function Get-StatusEmoji($value) {
    switch ($value) {
        { $_ -in 'none', 'operational', 'resolved', 'completed' }        { ':large_green_circle:'; break }
        { $_ -in 'minor', 'degraded_performance', 'monitoring' }         { ':large_yellow_circle:'; break }
        { $_ -in 'major', 'partial_outage', 'identified' }               { ':large_orange_circle:'; break }
        { $_ -in 'critical', 'major_outage', 'investigating' }           { ':red_circle:'; break }
        { $_ -in 'scheduled', 'in_progress', 'verifying', 'under_maintenance' } { ':wrench:'; break }
        default                                                          { ':white_circle:' }
    }
}

function Get-StatusColor($value) {
    switch ($value) {
        { $_ -in 'none', 'operational', 'resolved', 'completed' }        { '#2EB67D'; break }   # green
        { $_ -in 'minor', 'degraded_performance', 'monitoring' }         { '#ECB22E'; break }   # yellow
        { $_ -in 'major', 'partial_outage', 'identified' }               { '#F38020'; break }   # orange
        { $_ -in 'critical', 'major_outage', 'investigating' }           { '#E01E5A'; break }   # red
        { $_ -in 'scheduled', 'in_progress', 'verifying', 'under_maintenance' } { '#1D9BD1'; break }   # blue
        default                                                          { '#A0A0A0' }
    }
}

# Posts as an attachment: colored bar on the left (by status), label header, then the message
function Send-Slack($text, $status) {
    if ($DryRun) { Write-Host "---- would post ($(Get-StatusColor $status)) ----`n$Label`n$text`n"; return }
    $json = @{
        unfurl_links = $false
        attachments  = @(@{
            color    = Get-StatusColor $status
            fallback = ($text -replace '[*>]', '')
            blocks   = @(
                @{ type = 'context'; elements = @(@{ type = 'mrkdwn'; text = $Label }) },
                @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } }
            )
        })
    } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)   # PS 5.1 otherwise mangles non-ASCII
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes | Out-Null
}

function Format-Body($body) {
    $t = ($body -replace '\r', '' -replace '\n{3,}', "`n`n").Trim()
    if ($t.Length -gt 1500) { $t = $t.Substring(0, 1500) + '...' }
    # Slack mrkdwn needs &, <, > escaped
    $t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
}

# ---- load previous state ----
$firstRun = -not (Test-Path $StateFile)
$state = @{ indicator = $null; seenUpdates = @(); components = @{} }
if (-not $firstRun) {
    $saved = Get-Content $StateFile -Raw | ConvertFrom-Json
    $state.indicator   = $saved.indicator
    $state.seenUpdates = @($saved.seenUpdates)
    if ($saved.components) { $saved.components.PSObject.Properties | ForEach-Object { $state.components[$_.Name] = $_.Value } }
}
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$state.seenUpdates | ForEach-Object { [void]$seen.Add($_) }

# ---- fetch ----
$summary = Get-Api 'summary.json'
$items = @((Get-Api 'incidents.json').incidents | ForEach-Object { $_ | Add-Member -NotePropertyName kind -NotePropertyValue 'Incident' -PassThru })
if ($IncludeMaintenance) {
    $items += @((Get-Api 'scheduled-maintenances.json').scheduled_maintenances |
        ForEach-Object { $_ | Add-Member -NotePropertyName kind -NotePropertyValue 'Maintenance' -PassThru })
}

$groupNames = @{}
$summary.components | Where-Object group | ForEach-Object { $groupNames[$_.id] = $_.name }
$impactRank = @{ none = 0; minor = 1; major = 2; critical = 3 }

function Test-Wanted($item) {
    if ($item.kind -eq 'Incident' -and $impactRank[[string]$item.impact] -lt $impactRank[$MinImpact]) { return $false }
    if (-not $Categories.Count) { return $true }
    if (-not $item.components) { return -not $SkipUntagged }
    foreach ($c in $item.components) {
        foreach ($name in @($c.name, $groupNames[$c.group_id])) {
            if ($name -and ($Categories | Where-Object { $name -like $_ })) { return $true }
        }
    }
    $false
}

$messages = New-Object System.Collections.Generic.List[object]   # @{ text; status }

# ---- overall status ----
$indicator = $summary.status.indicator
if (-not $firstRun -and -not $SkipOverallStatus -and $state.indicator -and $indicator -ne $state.indicator) {
    $messages.Add(@{ status = $indicator; text = "$(Get-StatusEmoji $indicator) *Cloudflare status: $($summary.status.description)*  (<$StatusPage|status page>)" })
}

# ---- incident / maintenance updates (oldest first so Slack reads in order) ----
$newUpdates = foreach ($item in $items) {
    foreach ($u in $item.incident_updates) {
        if (-not $seen.Contains($u.id)) { [pscustomobject]@{ item = $item; update = $u } }
    }
}
if ($TestPost) {
    $latest = $items | Where-Object { $_.kind -eq 'Incident' } | Select-Object -First 1
    $newUpdates = @([pscustomobject]@{ item = $latest; update = $latest.incident_updates[0]; test = $true }) + @($newUpdates)
}
foreach ($n in ($newUpdates | Sort-Object { [datetime]$_.update.created_at })) {
    [void]$seen.Add($n.update.id)
    # filtered-out updates still count as seen, so changing the filter later doesn't replay them
    if (-not $n.test -and ($firstRun -or -not (Test-Wanted $n.item))) { continue }
    $i = $n.item; $u = $n.update
    $status = (Get-Culture).TextInfo.ToTitleCase(($u.status -replace '_', ' '))
    $affects = @($i.components.name)
    $affectsText = if ($affects.Count -gt 5) { ($affects[0..4] -join ', ') + " +$($affects.Count - 5) more" } else { $affects -join ', ' }
    $messages.Add(@{ status = $u.status; text =
        "$(Get-StatusEmoji $u.status) *$($n.item.kind) $($status):* <$($i.shortlink)|$(Format-Body $i.name)>`n" +
        "Impact: $($i.impact)$(if ($affectsText) { "  |  Affects: $(Format-Body $affectsText)" })`n" +
        "> $((Format-Body $u.body) -replace "`n", "`n> ")" })
}

# ---- watched components ----
$watched = @{}
if ($Components.Count) {
    foreach ($c in $summary.components) {
        if (-not ($Components | Where-Object { $c.name -like $_ })) { continue }
        $watched[$c.id] = $c.status
        $old = $state.components[$c.id]
        if (-not $firstRun -and $old -and $old -ne $c.status) {
            $messages.Add(@{ status = $c.status; text = "$(Get-StatusEmoji $c.status) *Component $($c.name):* $($old -replace '_',' ') -> $($c.status -replace '_',' ')" })
        }
    }
}

# ---- send + save ----
foreach ($m in $messages) { Send-Slack $m.text $m.status }

# keep only ids still present in the feeds so the state file doesn't grow forever
$liveIds = @($items | ForEach-Object { $_.incident_updates.id })
@{
    indicator   = $indicator
    seenUpdates = @($liveIds | Where-Object { $seen.Contains($_) })
    components  = $watched
} | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8

if ($firstRun) { Write-Host "First run: saved baseline ($indicator, $($seen.Count) updates). Nothing posted." }
else           { Write-Host "Posted $($messages.Count) message(s). Status: $($summary.status.description)" }

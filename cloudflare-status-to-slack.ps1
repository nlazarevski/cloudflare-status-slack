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

  The first run only records the current state and posts nothing, so you don't get flooded
  with the last 50 incidents.

.EXAMPLE
  $env:SLACK_WEBHOOK_URL = 'https://hooks.slack.com/services/XXX/YYY/ZZZ'
  .\cloudflare-status-to-slack.ps1

.EXAMPLE
  .\cloudflare-status-to-slack.ps1 -Components 'Dashboard','API','*Workers*' -DryRun
#>
param(
    [string]   $WebhookUrl = $env:SLACK_WEBHOOK_URL,
    [string]   $StatusPage = 'https://www.cloudflarestatus.com',
    [string[]] $Components = @(),           # wildcard names to watch; empty = none (Cloudflare lists ~480)
    [switch]   $IncludeMaintenance,
    [string]   $StateFile  = (Join-Path $PSScriptRoot 'cloudflare-status-state.json'),
    [switch]   $DryRun                      # print messages instead of posting
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

function Send-Slack($text) {
    if ($DryRun) { Write-Host "---- would post ----`n$text`n"; return }
    $json  = @{ text = $text; unfurl_links = $false } | ConvertTo-Json -Compress
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

$messages = New-Object System.Collections.Generic.List[string]

# ---- overall status ----
$indicator = $summary.status.indicator
if (-not $firstRun -and $state.indicator -and $indicator -ne $state.indicator) {
    $messages.Add("$(Get-StatusEmoji $indicator) *Cloudflare status: $($summary.status.description)*  (<$StatusPage|status page>)")
}

# ---- incident / maintenance updates (oldest first so Slack reads in order) ----
$newUpdates = foreach ($item in $items) {
    foreach ($u in $item.incident_updates) {
        if (-not $seen.Contains($u.id)) { [pscustomobject]@{ item = $item; update = $u } }
    }
}
foreach ($n in ($newUpdates | Sort-Object { [datetime]$_.update.created_at })) {
    [void]$seen.Add($n.update.id)
    if ($firstRun) { continue }
    $i = $n.item; $u = $n.update
    $status = (Get-Culture).TextInfo.ToTitleCase(($u.status -replace '_', ' '))
    $messages.Add(
        "$(Get-StatusEmoji $u.status) *$($n.item.kind) $($status):* <$($i.shortlink)|$(Format-Body $i.name)>`n" +
        "Impact: $($i.impact)`n" +
        "> $((Format-Body $u.body) -replace "`n", "`n> ")")
}

# ---- watched components ----
$watched = @{}
if ($Components.Count) {
    foreach ($c in $summary.components) {
        if (-not ($Components | Where-Object { $c.name -like $_ })) { continue }
        $watched[$c.id] = $c.status
        $old = $state.components[$c.id]
        if (-not $firstRun -and $old -and $old -ne $c.status) {
            $messages.Add("$(Get-StatusEmoji $c.status) *Component $($c.name):* $($old -replace '_',' ') -> $($c.status -replace '_',' ')")
        }
    }
}

# ---- send + save ----
foreach ($m in $messages) { Send-Slack $m }

# keep only ids still present in the feeds so the state file doesn't grow forever
$liveIds = @($items | ForEach-Object { $_.incident_updates.id })
@{
    indicator   = $indicator
    seenUpdates = @($liveIds | Where-Object { $seen.Contains($_) })
    components  = $watched
} | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8

if ($firstRun) { Write-Host "First run: saved baseline ($indicator, $($seen.Count) updates). Nothing posted." }
else           { Write-Host "Posted $($messages.Count) message(s). Status: $($summary.status.description)" }

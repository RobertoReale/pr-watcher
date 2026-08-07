<#
  init.ps1 - interactive setup wizard. Asks the handful of questions a new project needs
  answered, writes a config JSON, offers to create a blank brief file, and prints the next
  commands to run. It never touches engine/watch.ps1 - it only produces the config that drives it.

  Cross-platform (pwsh 7 on Windows or Linux). Run with no arguments:
    pwsh -File init.ps1
#>
$ErrorActionPreference = 'Stop'

function Ask([string]$prompt, [string]$default = $null, [switch]$Required) {
    while ($true) {
        $suffix = if ($default) { " [$default]" } else { '' }
        $val = Read-Host "$prompt$suffix"
        if (-not $val -and $default) { return $default }
        if (-not $val -and $Required) { Write-Host "  (required)" -ForegroundColor Yellow; continue }
        return $val
    }
}

function AskYesNo([string]$prompt, [bool]$defaultYes = $true) {
    $d = if ($defaultYes) { 'Y/n' } else { 'y/N' }
    $val = Read-Host "$prompt [$d]"
    if (-not $val) { return $defaultYes }
    return $val -match '^[Yy]'
}

Write-Host ''
Write-Host 'pr-watcher setup' -ForegroundColor Cyan
Write-Host 'A handful of questions, then a config file gets written for you.'
Write-Host ''

$projectLabel = Ask 'Project label (shown in notifications/logs)' -Required
$repo         = Ask 'GitHub repo being watched (owner/name)' -Required
$githubUser   = Ask 'Your GitHub username (the voice/account this acts as)' -Required

$seedRaw = Ask 'PR/issue numbers to watch from the start, comma-separated' -Required
$seedThreads = $seedRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { [int]$_ }

Write-Host ''
Write-Host 'The brief is the real "prompt": free-text context, what counts as your turn to move,' -ForegroundColor DarkGray
Write-Host 'any style/evidence rules. Claude reads it before deciding anything.' -ForegroundColor DarkGray
$briefPath = Ask 'Path to the project brief file' -Required
if (-not (Test-Path $briefPath)) {
    if (AskYesNo "That file does not exist yet. Create a blank template there?") {
        $labelUpper = $projectLabel
        @"
# $labelUpper - brief

## Who we are and what we're doing
(one paragraph: the goal, the repo, the PRs/issues in play)

## Where things stand
(the latest state of the negotiation/discussion, in your own words)

## What counts as "our turn to move" here
(be concrete: what should make the watcher act, what should make it stay silent)

## Voice / evidence rules specific to this project
(anything the generic watcher gates in engine/prompt.template.txt should not have to guess)
"@ | Set-Content -Path $briefPath -Encoding utf8
        Write-Host "  Created $briefPath - fill it in before the watcher runs for real." -ForegroundColor Green
    }
}

$projectDir = Ask 'Local working directory (repo checkout claude -p runs from)' -Required
$taskName   = Ask 'Task/timer name' "PR Watch - $projectLabel"
$interval   = [int](Ask 'Poll interval, in minutes' '20')

$hasMainPR = AskYesNo 'Does this watcher retire itself once a specific PR closes?' $false
$mainPR = $null; $graceDays = 14; $endReminder = $null
if ($hasMainPR) {
    $mainPR      = [int](Ask 'That PR number' -Required)
    $graceDays   = [int](Ask 'Days to keep watching after it closes (catches reverts/regressions)' '14')
    $endReminder = Ask 'Optional reminder to include in the end-of-mission report (blank to skip)' ''
    if (-not $endReminder) { $endReminder = $null }
}

$wantsSearch = AskYesNo 'Add discovery-search queries (catches threads nobody pinged you on)?' $true
$discoveryQueries = @()
if ($wantsSearch) {
    Write-Host '  Enter GitHub search queries one at a time, blank line to stop.' -ForegroundColor DarkGray
    while ($true) {
        $q = Read-Host '  query'
        if (-not $q) { break }
        $discoveryQueries += $q
    }
}

Write-Host ''
Write-Host 'How much can Claude do on its own here?' -ForegroundColor Cyan
Write-Host '  1) Read only - draft reports, never post anything'
Write-Host '  2) Read + comment - can reply on threads, cannot push or open PRs'
Write-Host '  3) Full - can also push to a fork and open PRs'
$permChoice = Ask 'Choice' '2'

$readTools = @('Read','Write','Edit','Glob','Grep','Bash','WebFetch','WebSearch','TodoWrite',
    'mcp__github__pull_request_read','mcp__github__issue_read','mcp__github__get_file_contents',
    'mcp__github__list_commits','mcp__github__get_commit','mcp__github__search_pull_requests',
    'mcp__github__search_issues','mcp__github__search_code')
$commentTools = @('mcp__github__add_issue_comment','mcp__github__add_reply_to_pull_request_comment',
    'mcp__github__add_comment_to_pending_review','mcp__github__pull_request_review_write')
$pushTools = @('mcp__github__create_pull_request','mcp__github__update_pull_request',
    'mcp__github__create_branch','mcp__github__push_files')

$allowedTools = switch ($permChoice) {
    '1' { $readTools }
    '3' { $readTools + $commentTools + $pushTools }
    default { $readTools + $commentTools }
}

$tokenEnvVar = Ask 'Environment variable holding the GitHub token' 'GH_TOKEN'
$tokenFile   = Ask 'Fallback file with a "GITHUB_TOKEN: <token>" line (blank to skip)' ''
if (-not $tokenFile) { $tokenFile = $null }

$defaultOut = Join-Path (Get-Location) (($projectLabel -replace '[^a-zA-Z0-9]+', '-').ToLower() + '.config.json')
$outPath = Ask 'Where to save the config' $defaultOut

$config = [ordered]@{
    projectLabel         = $projectLabel
    repo                 = $repo
    githubUser           = $githubUser
    seedThreads          = $seedThreads
    discoveryQueries     = $discoveryQueries
    briefPath            = $briefPath
    projectDir           = $projectDir
    watchDir             = $null
    taskName             = $taskName
    intervalMinutes      = $interval
    mainPR               = $mainPR
    graceDays            = $graceDays
    endOfMissionReminder = $endReminder
    tokenEnvVar          = $tokenEnvVar
    tokenFile            = $tokenFile
    # Keeps the launched `claude` on the subscription login even if an API key happens to be in
    # the environment. Set to false in the config if you want this billed to the metered API.
    useSubscriptionOnly  = $true
    allowedTools         = $allowedTools
}

$config | ConvertTo-Json -Depth 5 | Set-Content -Path $outPath -Encoding utf8

Write-Host ''
Write-Host "Config written to $outPath" -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
$enginePath = Join-Path $PSScriptRoot 'engine\watch.ps1'
Write-Host "  pwsh -File `"$enginePath`" -ConfigPath `"$outPath`" -WhatIf      (dry run)"
Write-Host "  pwsh -File `"$enginePath`" -ConfigPath `"$outPath`" -TestToast   (check notifications)"
Write-Host "  pwsh -File `"$enginePath`" -ConfigPath `"$outPath`" -Install     (start watching for real)"

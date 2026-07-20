<#
  watch.ps1 - generic engine. It watches a GitHub conversation (a repo, a seed list of
  PRs/issues, plus whatever notifications and discovery search turn up) and wakes Claude Code
  headless to analyse anything new and, if it's your turn to move, act on it.

  This file has NO project-specific knowledge. Everything that changes between projects lives
  in a config JSON (see ../examples/*.config.json) and in that project's own brief file, which
  Claude is told to read for context and rules before deciding anything. To watch a new project:
  copy an example config, point it at your brief, and run with -Install.

  Three sources feed a watchlist that grows on its own:
    1. WATCHLIST POLL (the spine) - for every thread already known, fetch comments and (for
       PRs) the head SHA. A new comment by someone else, or a force-push, is an event. Cached
       with ETags: a thread nobody touched since the last poll costs a 304, not a full request,
       so the polling cost does not grow with how many threads you watch.
    2. NOTIFICATIONS - /notifications?all=true, so already-read ones still count.
    3. DISCOVERY SEARCH - config-defined search queries, to catch a thread nobody CC'd you on.

  Claude is launched with whatever autonomy the config's "allowedTools" grants (default: read
  and comment, no push/PR rights - add mcp__github__create_pull_request / push_files /
  create_branch yourself if you want it to open PRs too). It always leaves a receipt in
  DraftDir + LATEST.md with the exact text it published, so you can edit or delete anything
  you disagree with.

  NOTE: keep this file pure ASCII. Windows PowerShell 5.1 (used only for the toast) reads .ps1
  as ANSI, and non-ASCII characters corrupt the parse.

  Usage:
    pwsh -File watch.ps1 -ConfigPath .\my-project.config.json -WhatIf
    pwsh -File watch.ps1 -ConfigPath .\my-project.config.json -Install
    pwsh -File watch.ps1 -ConfigPath .\my-project.config.json -TestToast
    pwsh -File watch.ps1 -ConfigPath .\my-project.config.json -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [switch]$WhatIf,     # report what it would do; never launch Claude, never write state
    [switch]$Reset,      # forget all state and re-baseline from scratch
    [switch]$Install,    # register the scheduled task described by the config, then exit
    [switch]$Uninstall,  # remove the scheduled task and stop watching, now
    [switch]$TestToast   # fire a sample notification and exit, to prove the channel works
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$ConfigPath = (Resolve-Path $ConfigPath).Path

function Req($name) {
    if (-not $Config.$name) { throw "Config is missing required field '$name' ($ConfigPath)" }
    return $Config.$name
}

$ProjectLabel = Req 'projectLabel'
$Repo         = Req 'repo'
$Me           = Req 'githubUser'
$Seed         = @(Req 'seedThreads')
$BriefPath    = Req 'briefPath'
$ProjectDir   = Req 'projectDir'
$TaskName     = Req 'taskName'

$WatchDir     = if ($Config.watchDir) { $Config.watchDir } else {
    Join-Path $env:LOCALAPPDATA ("pr-watch\" + ($TaskName -replace '[^a-zA-Z0-9]+', '-'))
}
$IntervalMin  = if ($Config.intervalMinutes) { [int]$Config.intervalMinutes } else { 20 }
$MainPR       = if ($Config.mainPR) { [int]$Config.mainPR } else { $null }
$GraceDays    = if ($Config.graceDays) { [int]$Config.graceDays } else { 14 }
$EndReminder  = if ($Config.endOfMissionReminder) { [string]$Config.endOfMissionReminder } else { $null }
$Queries      = if ($Config.discoveryQueries) { @($Config.discoveryQueries) } else { @() }
$TokenEnvVar  = if ($Config.tokenEnvVar) { [string]$Config.tokenEnvVar } else { 'GH_TOKEN' }
$TokenFile    = if ($Config.tokenFile) { [string]$Config.tokenFile } else { $null }
$AllowedTools = if ($Config.allowedTools) { (@($Config.allowedTools) -join ',') } else {
    'Read,Write,Edit,Glob,Grep,Bash,WebFetch,WebSearch,TodoWrite,' +
    'mcp__github__pull_request_read,mcp__github__issue_read,mcp__github__get_file_contents,' +
    'mcp__github__list_commits,mcp__github__get_commit,mcp__github__search_pull_requests,' +
    'mcp__github__search_issues,mcp__github__search_code,mcp__github__add_issue_comment,' +
    'mcp__github__add_reply_to_pull_request_comment,mcp__github__add_comment_to_pending_review,' +
    'mcp__github__pull_request_review_write'
}
$PromptFile   = if ($Config.promptTemplate) { [string]$Config.promptTemplate } else {
    Join-Path $PSScriptRoot 'prompt.template.txt'
}

$StateFile = Join-Path $WatchDir 'state.json'
$LogFile   = Join-Path $WatchDir 'watch.log'
$DraftDir  = Join-Path $WatchDir 'drafts'

New-Item -ItemType Directory -Force -Path $WatchDir, $DraftDir | Out-Null

function Write-Log($msg) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

# --- install / uninstall -------------------------------------------------------------------
function Stop-Watching([string]$why) {
    Write-Log "RETIRING: $why"
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log "Scheduled task '$TaskName' removed. Nothing will run again."
    } catch {
        Write-Log "WARN: could not remove the scheduled task ($($_.Exception.Message))"
    }
}

if ($Uninstall) { Stop-Watching 'requested manually (-Uninstall)'; exit 0 }

if ($Install) {
    $enginePath = Join-Path $PSScriptRoot 'watch.ps1'
    $action  = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-File `"$enginePath`" -ConfigPath `"$ConfigPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)).Repetition
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -RunLevel Limited -Force | Out-Null
    Write-Log "Installed scheduled task '$TaskName', every $IntervalMin min, logon-triggered (Interactive: needed for the toast)."
    Write-Output "Installed. Test it with: pwsh -File `"$enginePath`" -ConfigPath `"$ConfigPath`" -WhatIf"
    exit 0
}

# --- notifications -----------------------------------------------------------------------
# WinRT toast APIs do not exist in PowerShell 7, so this is delegated to Windows PowerShell 5.1,
# under an AppID Windows already knows (otherwise it silently drops the toast).
function Show-Toast([string]$title, [string]$body) {
    $script = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
`$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$xml.LoadXml(@'
<toast scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>$title</text>
    <text>$body</text>
  </binding></visual>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
'@)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$AppId).Show(
    [Windows.UI.Notifications.ToastNotification]::new(`$xml))
"@
    try {
        $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $b64  = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        & $ps51 -NoProfile -EncodedCommand $b64 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log 'Toast sent.'; return $true }
        Write-Log "WARN: toast exited $LASTEXITCODE"
        return $false
    }
    catch {
        Write-Log "WARN: toast failed ($($_.Exception.Message))"
        return $false
    }
}

if ($TestToast) {
    $ok = Show-Toast $ProjectLabel 'Test notification. If you can see this, the channel works.'
    if ($ok) { Write-Log 'TestToast: delivered to Windows. If you cannot see it, check Windows notification settings.' }
    exit 0
}

# --- auth -------------------------------------------------------------------------------
$token = [Environment]::GetEnvironmentVariable($TokenEnvVar)
if (-not $token -and $TokenFile -and (Test-Path $TokenFile)) {
    $m = Select-String -Path $TokenFile -Pattern '^GITHUB_TOKEN:\s*(\S+)' | Select-Object -First 1
    if ($m) { $token = $m.Matches[0].Groups[1].Value }
}
if (-not $token) { Write-Log "ERROR: no token in `$$TokenEnvVar and no usable tokenFile"; exit 1 }

$H = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'pr-watcher'
}

function Get-Api($url) {
    try { return Invoke-RestMethod -Uri $url -Headers $H -Method Get }
    catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
        throw
    }
}

# Conditional GET for the high-frequency spine poll (PR head + comments, once per watched
# thread, every run, forever). A 304 (nothing changed since our stored ETag) does not count
# against the GitHub rate limit, unlike a plain 200 - this is what lets the watchlist grow
# without the polling cost growing with it.
function Get-ApiCached([string]$url) {
    $headers = $H.Clone()
    if ($state.etags.ContainsKey($url)) { $headers['If-None-Match'] = $state.etags[$url] }
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get
        if ($resp.Headers['ETag']) { $state.etags[$url] = [string]$resp.Headers['ETag'][0] }
        return [pscustomobject]@{ Data = ($resp.Content | ConvertFrom-Json); Changed = $true }
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ }
        if ($status -eq 304) { return [pscustomobject]@{ Data = $null; Changed = $false } }
        if ($status -eq 404) { return [pscustomobject]@{ Data = $null; Changed = $true } }
        throw
    }
}

# --- state --------------------------------------------------------------------------------
$state = @{ threads = @{}; ignore = @(); mainClosedSeen = $false; etags = @{} }
if ((Test-Path $StateFile) -and -not $Reset) {
    try {
        $raw = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($raw.ignore)  { $state.ignore = @($raw.ignore) }
        if ($null -ne $raw.mainClosedSeen) { $state.mainClosedSeen = [bool]$raw.mainClosedSeen }
        if ($raw.etags) {
            $raw.etags.PSObject.Properties | ForEach-Object { $state.etags[$_.Name] = [string]$_.Value }
        }
        if ($raw.threads) {
            $raw.threads.PSObject.Properties | ForEach-Object {
                $state.threads[$_.Name] = @{
                    lastComment = [int64]$_.Value.lastComment
                    head        = [string]$_.Value.head
                    title       = [string]$_.Value.title
                }
            }
        }
    } catch { Write-Log "WARN: unreadable state, starting fresh ($($_.Exception.Message))" }
}

$known = [System.Collections.Generic.HashSet[int]]::new()
$state.threads.Keys | ForEach-Object { [void]$known.Add([int]$_) }
$state.ignore       | ForEach-Object { [void]$known.Add([int]$_) }

$events     = @()
$discovered = @()
$prevSeen   = @{}

# --- end of mission? (only if the config defines a mainPR) --------------------------------
if ($MainPR) {
    $main = Get-Api "https://api.github.com/repos/$Repo/pulls/$MainPR"
    if ($main -and $main.state -eq 'closed') {
        $closedAt = ([datetime]$main.closed_at).ToLocalTime()
        $days     = ((Get-Date) - $closedAt).TotalDays
        $verdict  = if ($main.merged) { 'MERGED' } else { 'CLOSED without merge' }

        if (-not $state.mainClosedSeen) {
            Write-Log "PR #$MainPR is $verdict (on $($closedAt.ToString('yyyy-MM-dd')))"
            $state.mainClosedSeen = $true
            $text = "The tracked PR was closed ($verdict). This watcher keeps running for $GraceDays more days to catch reverts, regressions and follow-up, then retires itself."
            if ($EndReminder) { $text += "`n`nREMINDER: $EndReminder" }
            $events += [pscustomobject]@{
                Kind = "END OF MISSION: PR #$MainPR $verdict"; Number = $MainPR; Author = '-'
                Text = $text; Url = "https://github.com/$Repo/pull/$MainPR"
            }
        }

        if ($days -ge $GraceDays) {
            if (-not $WhatIf) { $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8 }
            Stop-Watching ("PR #$MainPR $verdict " + [math]::Floor($days) + " days ago, past the $GraceDays-day grace period")
            exit 0
        }
        Write-Log ("Grace period: " + [math]::Floor($days) + "/$GraceDays days since closing")
    }
}

function Add-Thread([int]$n, [string]$title, [string]$why) {
    if ($known.Contains($n)) { return }
    [void]$known.Add($n)
    $script:discovered += [pscustomobject]@{ Number = $n; Title = $title; Why = $why }
    Write-Log "DISCOVERED #$n via $why - $title"
}

# --- source 1: seed -----------------------------------------------------------------------
foreach ($n in $Seed) { Add-Thread ([int]$n) '(seed)' 'seed' }

# --- source 2: notifications (all=true, so read ones still count) --------------------------
try {
    $notifs = Get-Api 'https://api.github.com/notifications?all=true&per_page=50'
    foreach ($nt in $notifs) {
        if ($nt.repository.full_name -ne $Repo) { continue }
        if ($nt.subject.url -match '/(\d+)$') {
            Add-Thread ([int]$Matches[1]) $nt.subject.title 'notification'
        }
    }
} catch { Write-Log "WARN: notifications poll failed ($($_.Exception.Message))" }

# --- source 3: discovery search (config-defined queries; empty = skip) --------------------
foreach ($q in $Queries) {
    try {
        $enc = [uri]::EscapeDataString($q)
        $res = Get-Api ('https://api.github.com/search/issues?q=' + $enc + '&per_page=30')
        foreach ($it in $res.items) { Add-Thread ([int]$it.number) $it.title 'search' }
    } catch { Write-Log "WARN: search failed ($($_.Exception.Message))" }
}

foreach ($d in ($discovered | Where-Object { $_.Why -ne 'seed' })) {
    $events += [pscustomobject]@{
        Kind = 'NEW THREAD'; Number = $d.Number; Author = '?'
        Text = "$($d.Title) (found via $($d.Why))"; Url = "https://github.com/$Repo/issues/$($d.Number)"
    }
}

# --- the spine: poll every watched thread, cached ------------------------------------------
foreach ($n in ($known | Sort-Object)) {
    if ($state.ignore -contains $n) { continue }

    $key   = [string]$n
    $isNew = -not $state.threads.ContainsKey($key)
    $prev  = if ($isNew) { @{ lastComment = 0; head = ''; title = '' } } else { $state.threads[$key] }

    $prUrl = "https://api.github.com/repos/$Repo/pulls/$n"
    $prRes = Get-ApiCached $prUrl
    $pr    = $prRes.Data
    $head  = if (-not $prRes.Changed) { $prev.head }
             elseif ($pr)             { [string]$pr.head.sha }
             else                     { '' }
    $title = if (-not $prRes.Changed) { $prev.title }
             elseif ($pr)             { [string]$pr.title }
             else {
                 $iss = Get-Api "https://api.github.com/repos/$Repo/issues/$n"
                 if ($iss) { [string]$iss.title } else { $prev.title }
             }

    if (-not $isNew -and $head -and $prev.head -and ($head -ne $prev.head)) {
        $a = $prev.head.Substring(0, 9)
        $b = $head.Substring(0, 9)
        Write-Log "PR #$n HEAD CHANGED $a -> $b"
        $events += [pscustomobject]@{
            Kind = 'NEW COMMITS / FORCE-PUSH'; Number = $n; Author = '-'
            Text = "head $a -> $b : the diff may no longer be what it was"
            Url  = "https://github.com/$Repo/pull/$n/files"
        }
    }

    $comments   = @()
    $anyChanged = $false
    foreach ($u in @(
        "https://api.github.com/repos/$Repo/issues/$n/comments?per_page=100",
        "https://api.github.com/repos/$Repo/pulls/$n/comments?per_page=100"
    )) {
        $r = Get-ApiCached $u
        if ($r.Changed) { $anyChanged = $true }
        if ($r.Data) { $comments += $r.Data }
    }

    $newest = if ($comments) { ($comments | Measure-Object -Property id -Maximum).Maximum } else { $prev.lastComment }

    if ($isNew) {
        Write-Log "WATCH #$n baseline (comment $newest) - $title"
    }
    elseif (-not $anyChanged) {
        Write-Log "WATCH #$n nothing new (cached)"
    }
    else {
        $fresh = $comments | Where-Object {
            $_.id -gt $prev.lastComment -and $_.user.login -ne $Me -and $_.user.type -ne 'Bot'
        }
        foreach ($c in $fresh) {
            Write-Log "COMMENT #$n by $($c.user.login) (id $($c.id))"
            $snippet = ($c.body -replace '\s+', ' ')
            if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) + '...' }
            $events += [pscustomobject]@{
                Kind = 'COMMENT'; Number = $n; Author = $c.user.login; Text = $snippet; Url = $c.html_url
            }
        }
        if (-not $fresh) { Write-Log "WATCH #$n nothing new" }
    }

    $prevSeen[$key] = $prev.lastComment
    $state.threads[$key] = @{ lastComment = $newest; head = $head; title = $title }
}

$stateBeforeRun = $state | ConvertTo-Json -Depth 5
if (-not $WhatIf) { $stateBeforeRun | Set-Content -Path $StateFile -Encoding utf8 }

if (-not $events) { exit 0 }

$statePreEvent = @{ threads = @{}; ignore = $state.ignore; mainClosedSeen = $state.mainClosedSeen; etags = $state.etags }
foreach ($k in $state.threads.Keys) {
    $ev = $events | Where-Object { [string]$_.Number -eq $k } | Select-Object -First 1
    $statePreEvent.threads[$k] = @{
        lastComment = if ($ev) { $prevSeen[$k] } else { $state.threads[$k].lastComment }
        head        = $state.threads[$k].head
        title       = $state.threads[$k].title
    }
}

# --- wake Claude --------------------------------------------------------------------------
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$draft   = Join-Path $DraftDir "report_$stamp.md"
$authors = (($events | Where-Object { $_.Author -notin @('?', '-') }).Author | Select-Object -Unique) -join ', '
if (-not $authors) { $authors = 'GitHub' }

$list = ($events | ForEach-Object {
    "### [$($_.Kind)] #$($_.Number) - $($_.Author)`n$($_.Url)`n> $($_.Text)"
}) -join "`n`n"

if (-not (Test-Path $PromptFile)) { throw "Prompt template not found: $PromptFile" }
$prompt = Get-Content $PromptFile -Raw
$prompt = $prompt.Replace('{{PROJECT_LABEL}}', $ProjectLabel)
$prompt = $prompt.Replace('{{EVENTS_LIST}}', $list)
$prompt = $prompt.Replace('{{BRIEF_PATH}}', $BriefPath)
$prompt = $prompt.Replace('{{STATE_FILE}}', $StateFile)
$prompt = $prompt.Replace('{{DRAFT_FILE}}', $draft)
$prompt = $prompt.Replace('{{GITHUB_USER}}', $Me)

Write-Log "Waking Claude: $($events.Count) event(s) [$authors] -> $draft"
if ($WhatIf) { Write-Log 'WhatIf: Claude not launched.'; exit 0 }

$rawLog = Join-Path $WatchDir "run_$stamp.jsonl"

Push-Location $ProjectDir
try {
    $prompt | & claude -p --output-format stream-json --verbose `
                --allowedTools $AllowedTools --permission-mode acceptEdits --add-dir $WatchDir 2>&1 |
        ForEach-Object {
            $line = $_
            Add-Content -Path $rawLog -Value $line
            try {
                $o = $line | ConvertFrom-Json -ErrorAction Stop
                switch ($o.type) {
                    'assistant' {
                        foreach ($c in $o.message.content) {
                            if ($c.type -eq 'tool_use') {
                                $arg = ''
                                if ($c.input.command)   { $arg = $c.input.command }
                                elseif ($c.input.file_path) { $arg = $c.input.file_path }
                                elseif ($c.input.pattern)   { $arg = $c.input.pattern }
                                if ($arg.Length -gt 70) { $arg = $arg.Substring(0, 70) + '...' }
                                Write-Log "   -> $($c.name) $arg"
                            }
                            elseif ($c.type -eq 'text' -and $c.text.Trim()) {
                                $t = ($c.text -replace '\s+', ' ').Trim()
                                if ($t.Length -gt 110) { $t = $t.Substring(0, 110) + '...' }
                                Write-Log "   .. $t"
                            }
                        }
                    }
                    'result' { Write-Log "   == $($o.subtype) (turns: $($o.num_turns), cost: $([math]::Round($o.total_cost_usd,3)) USD)" }
                    'rate_limit_event' { Write-Log "   !! Rate limit event received (resetsAt: $($o.rate_limit_info.resetsAt))" }
                }
            }
            catch { }
        }
    Write-Log "Claude finished (exit $LASTEXITCODE)"
}
finally { Pop-Location }

# Auto-postpone if Claude hit the weekly/daily rate limit.
$rateLimitResetsAt = $null
if ($LASTEXITCODE -ne 0 -and (Test-Path $rawLog)) {
    try {
        foreach ($line in (Get-Content $rawLog -ErrorAction SilentlyContinue)) {
            if ($line.Trim() -and $line.StartsWith('{')) {
                $evt = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($evt -and $evt.type -eq 'rate_limit_event' -and $evt.rate_limit_info -and $evt.rate_limit_info.status -eq 'rejected' -and $evt.rate_limit_info.resetsAt) {
                    $rateLimitResetsAt = [int64]$evt.rate_limit_info.resetsAt
                    break
                }
            }
        }
    } catch { }
}

if ($null -ne $rateLimitResetsAt -and $rateLimitResetsAt -gt 0) {
    Write-Log "RATE LIMIT hit! Resets at Unix timestamp $rateLimitResetsAt - rewinding state and postponing task."
    $statePreEvent | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8

    $epoch = [datetime]'1970-01-01T00:00:00Z'
    $resetUtc = $epoch.AddSeconds($rateLimitResetsAt)
    $newStart = $resetUtc.ToLocalTime().AddMinutes(5)

    try {
        $t = New-ScheduledTaskTrigger -Once -At ($newStart.ToString('yyyy-MM-ddTHH:mm:ss')) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
        Set-ScheduledTask -TaskName $TaskName -Trigger $t -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Log "Scheduled task '$TaskName' auto-postponed to start on $($newStart.ToString('yyyy-MM-dd HH:mm:ss')) ($IntervalMin m repetition)."
    } catch {
        Write-Log "WARN: could not auto-postpone scheduled task ($($_.Exception.Message))"
    }

    Show-Toast $ProjectLabel "Claude hit a rate limit. Task auto-paused until $($newStart.ToString('yyyy-MM-dd HH:mm'))" | Out-Null
    exit 0
}

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $draft)) {
    Write-Log "FAILED run (exit $LASTEXITCODE, report: $(Test-Path $draft)) - rewinding state so the next run retries"
    $statePreEvent | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8
}

# --- notify -------------------------------------------------------------------------------
if (Test-Path $draft) {
    Write-Log "REPORT: $draft"
    Copy-Item $draft (Join-Path $WatchDir 'LATEST.md') -Force

    $gist = (Get-Content $draft | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' } |
             Select-Object -First 1)
    if (-not $gist) { $gist = "See $WatchDir\LATEST.md" }

    $acted = $gist -match '^\s*ACTION'
    $head  = if ($acted) { "$ProjectLabel : published ($authors)" }
             else        { "$ProjectLabel : activity, no action ($authors)" }

    $gist = $gist -replace '^\s*(NO ACTION|ACTION)\s*:\s*', ''
    if ($gist.Length -gt 160) { $gist = $gist.Substring(0, 160) + '...' }

    Write-Log ("Verdict: " + $(if ($acted) { 'ACTED' } else { 'no action' }) + " - $gist")
    Show-Toast $head "$gist -- details in $WatchDir\LATEST.md" | Out-Null
}
else {
    Write-Log 'WARN: Claude ran but produced no report file.'
    Show-Toast "$ProjectLabel : activity" `
               "$($events.Count) event(s) ($authors), but no report. Check GitHub and watch.log" | Out-Null
}

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

  CROSS-PLATFORM: pwsh 7 runs on both. -Install registers a Windows Task Scheduler task (logon
  trigger, needed for the toast) or, on Linux, a "systemctl --user" timer. The desktop toast
  uses WinRT via Windows PowerShell 5.1 on Windows, or "notify-send" on Linux if present;
  otherwise it just logs a warning and relies on watch.log / LATEST.md. A rate-limit backoff is
  a plain marker file (postponed_until.txt), not a scheduler edit, so it works the same on both.

  UNATTENDED-SAFE. This thing runs for months with nobody looking at it, so every failure mode
  it has actually hit in production is contained here rather than left to a human to notice:
  every HTTP call has a timeout and one retry (pwsh's default timeout is INFINITE, and one
  stalled socket used to hang a run until the scheduler's time limit killed it, blinding the
  watcher for hours); a thread that throws is skipped instead of taking the rest of the run with
  it; stored ETags are validated before being sent back, because one malformed value used to
  poison an endpoint permanently, and the ETags of threads that produced an event are dropped on
  rollback, otherwise the retry gets a 304 and never re-sees the event it was meant to retry.

  NOTE: keep this file pure ASCII. Windows PowerShell 5.1 (used only for the Windows toast)
  reads .ps1 as ANSI, and non-ASCII characters corrupt the parse.

  Usage:
    pwsh -File watch.ps1 -ConfigPath ./my-project.config.json -WhatIf
    pwsh -File watch.ps1 -ConfigPath ./my-project.config.json -Install
    pwsh -File watch.ps1 -ConfigPath ./my-project.config.json -TestToast
    pwsh -File watch.ps1 -ConfigPath ./my-project.config.json -Uninstall
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
    $base = if ($IsWindows) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local/share' }
    Join-Path $base (Join-Path 'pr-watch' ($TaskName -replace '[^a-zA-Z0-9]+', '-'))
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
# The `claude` CLI silently prefers an API key over the subscription login when one is present
# in the environment. A watcher that fires every 20 minutes for months would then quietly run on
# metered credits. Default: blank those variables for the child process only. Set this to false
# in the config if you actually mean to bill this to the API (or to Bedrock/Vertex).
$SubscriptionOnly = if ($null -ne $Config.useSubscriptionOnly) { [bool]$Config.useSubscriptionOnly } else { $true }
$ApiTimeoutSec    = if ($Config.apiTimeoutSeconds) { [int]$Config.apiTimeoutSeconds } else { 30 }

$StateFile = Join-Path $WatchDir 'state.json'
$LogFile   = Join-Path $WatchDir 'watch.log'
$DraftDir  = Join-Path $WatchDir 'drafts'

New-Item -ItemType Directory -Force -Path $WatchDir, $DraftDir | Out-Null

function Write-Log($msg) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

# --- install / uninstall (platform-specific scheduler) -------------------------------------
function Get-UnitSlug { ($TaskName -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLower() }

function Install-Windows {
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
    Write-Log "Installed Windows scheduled task '$TaskName', every $IntervalMin min, logon-triggered (Interactive: needed for the toast)."
}

function Uninstall-Windows {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log "Windows scheduled task '$TaskName' removed. Nothing will run again."
    } catch {
        Write-Log "WARN: could not remove the scheduled task ($($_.Exception.Message))"
    }
}

function Install-Linux {
    $unit     = Get-UnitSlug
    $userDir  = Join-Path $HOME '.config/systemd/user'
    New-Item -ItemType Directory -Force -Path $userDir | Out-Null
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = 'pwsh' }
    $enginePath = Join-Path $PSScriptRoot 'watch.ps1'

    @"
[Unit]
Description=pr-watcher: $TaskName

[Service]
Type=oneshot
ExecStart=$pwshPath -File "$enginePath" -ConfigPath "$ConfigPath"
"@ | Set-Content -Path (Join-Path $userDir "pr-watcher-$unit.service") -Encoding utf8

    @"
[Unit]
Description=pr-watcher timer: $TaskName

[Timer]
OnBootSec=2min
OnUnitActiveSec=${IntervalMin}min
Persistent=true

[Install]
WantedBy=timers.target
"@ | Set-Content -Path (Join-Path $userDir "pr-watcher-$unit.timer") -Encoding utf8

    & systemctl --user daemon-reload
    & systemctl --user enable --now "pr-watcher-$unit.timer"
    Write-Log "Installed systemd --user timer 'pr-watcher-$unit.timer', every $IntervalMin min."
    Write-Log "NOTE: toasts need 'notify-send' (libnotify) and a running session/DBus; otherwise only watch.log/LATEST.md are written."
}

function Uninstall-Linux {
    $unit    = Get-UnitSlug
    $userDir = Join-Path $HOME '.config/systemd/user'
    try {
        & systemctl --user disable --now "pr-watcher-$unit.timer" 2>&1 | Out-Null
        Remove-Item (Join-Path $userDir "pr-watcher-$unit.timer") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $userDir "pr-watcher-$unit.service") -Force -ErrorAction SilentlyContinue
        & systemctl --user daemon-reload
        Write-Log "systemd --user timer 'pr-watcher-$unit.timer' removed. Nothing will run again."
    } catch {
        Write-Log "WARN: could not remove the systemd timer ($($_.Exception.Message))"
    }
}

function Stop-Watching([string]$why) {
    Write-Log "RETIRING: $why"
    if ($IsWindows) { Uninstall-Windows } else { Uninstall-Linux }
}

if ($Uninstall) { Stop-Watching 'requested manually (-Uninstall)'; exit 0 }

if ($Install) {
    if ($IsWindows) { Install-Windows } else { Install-Linux }
    $enginePath = Join-Path $PSScriptRoot 'watch.ps1'
    Write-Output "Installed. Test it with: pwsh -File `"$enginePath`" -ConfigPath `"$ConfigPath`" -WhatIf"
    exit 0
}

# --- notifications -----------------------------------------------------------------------
# WinRT toast APIs do not exist in PowerShell 7, so on Windows this is delegated to Windows
# PowerShell 5.1, under an AppID Windows already knows (otherwise it silently drops the toast).
# On Linux it uses notify-send if present; if not, it just logs a warning - the report in
# LATEST.md and watch.log are the guaranteed record either way.
function Show-Toast([string]$title, [string]$body) {
    if ($IsWindows) {
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
    elseif (Get-Command notify-send -ErrorAction SilentlyContinue) {
        try {
            & notify-send -- $title $body
            if ($LASTEXITCODE -eq 0) { Write-Log 'Toast sent (notify-send).'; return $true }
            Write-Log "WARN: notify-send exited $LASTEXITCODE"
            return $false
        }
        catch {
            Write-Log "WARN: notify-send failed ($($_.Exception.Message))"
            return $false
        }
    }
    else {
        Write-Log 'WARN: no desktop notification available (notify-send not found). Check watch.log / LATEST.md.'
        return $false
    }
}

if ($TestToast) {
    $ok = Show-Toast $ProjectLabel 'Test notification. If you can see this, the channel works.'
    if ($ok) { Write-Log 'TestToast: delivered. If you cannot see it, check your OS notification settings.' }
    exit 0
}

# --- rate-limit backoff marker (platform-agnostic: no scheduler edit needed) --------------
$PostponeFile = Join-Path $WatchDir 'postponed_until.txt'
if (Test-Path $PostponeFile) {
    try {
        $until = [datetime]::Parse((Get-Content $PostponeFile -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ((Get-Date) -lt $until) {
            Write-Log "Postponed until $($until.ToString('yyyy-MM-dd HH:mm:ss')) (rate-limit backoff) - skipping this run."
            exit 0
        }
        Remove-Item $PostponeFile -Force -ErrorAction SilentlyContinue
    } catch { Remove-Item $PostponeFile -Force -ErrorAction SilentlyContinue }
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

# Every HTTP call MUST carry -TimeoutSec. PowerShell 7's default is *infinite*: a single stalled
# connection hangs the whole run, and because the scheduler refuses overlapping instances, every
# run after it is skipped until the execution time limit kills the first one - hours blind, with
# nothing in watch.log to say so. One retry, because a stall is usually transient.
function Get-Api($url) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try { return Invoke-RestMethod -Uri $url -Headers $H -Method Get -TimeoutSec $ApiTimeoutSec }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
            if ($attempt -eq 2) { throw }
            Write-Log "WARN: $url failed ($($_.Exception.Message)), retry"
            Start-Sleep -Seconds 3
        }
    }
}

# Conditional GET for the high-frequency spine poll (PR head + comments, once per watched
# thread, every run, forever). A 304 (nothing changed since our stored ETag) does not count
# against the GitHub rate limit, unlike a plain 200 - this is what lets the watchlist grow
# without the polling cost growing with it.
function Get-ApiCached([string]$url) {
    $headers = $H.Clone()
    # Only send back a validator that is actually well formed. A truncated one ("W") once got
    # stored, and .NET then rejected every request to that URL with "The format of value 'W' is
    # invalid" - forever, because the bad value lived in state.json. A malformed ETag is worth
    # one uncached 200, never a permanently dead endpoint.
    if ($state.etags.ContainsKey($url)) {
        $tag = [string]$state.etags[$url]
        if ($tag -match '^(W/)?"[^"]*"$') { $headers['If-None-Match'] = $tag }
        else { $state.etags.Remove($url) }
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -TimeoutSec $ApiTimeoutSec
            # @(...) first: PowerShell hands this header back as a string[] sometimes and as a
            # bare string others, and indexing [0] into a bare string yields its first CHARACTER,
            # the "W" of W/"...". That is exactly how the poisoned value above was produced.
            if ($resp.Headers['ETag']) { $state.etags[$url] = [string](@($resp.Headers['ETag'])[0]) }
            return [pscustomobject]@{ Data = ($resp.Content | ConvertFrom-Json); Changed = $true }
        }
        catch {
            $status = $null
            if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ }
            if ($status -eq 304) { return [pscustomobject]@{ Data = $null; Changed = $false } }
            if ($status -eq 404) { return [pscustomobject]@{ Data = $null; Changed = $true } }
            if ($attempt -eq 2) { throw }
            Write-Log "WARN: $url failed ($($_.Exception.Message)), retry"
            Start-Sleep -Seconds 3
        }
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

    # One bad thread must not take the run down with it. Threads are polled in numeric order, so
    # without this a single failing URL kills every thread after it, plus the state write and the
    # Claude launch - and the log shows only a WARN, which reads like a survived hiccup. A thread
    # that throws keeps its previous state, so the next run retries it from where it was.
    try {
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
    catch {
        Write-Log "ERROR: thread #$n poll failed ($($_.Exception.Message)) - skipped, will retry next run"
    }
}

# The state is advanced BEFORE waking Claude, so a comment can never be answered twice. The cost
# of that choice is the opposite risk: if Claude dies mid-run the comment is already marked seen
# and would be silently dropped. So keep a snapshot to roll back to on failure, and let the next
# run retry it.
$stateBeforeRun = $state | ConvertTo-Json -Depth 5
if (-not $WhatIf) { $stateBeforeRun | Set-Content -Path $StateFile -Encoding utf8 }

if (-not $events) { exit 0 }

$statePreEvent = @{ threads = @{}; ignore = $state.ignore; mainClosedSeen = $state.mainClosedSeen; etags = @{} }
$rewound = @()
foreach ($k in $state.threads.Keys) {
    $ev = $events | Where-Object { [string]$_.Number -eq $k } | Select-Object -First 1
    if ($ev) { $rewound += $k }
    $statePreEvent.threads[$k] = @{
        # rewind only the threads that produced an event, so only those get retried
        lastComment = if ($ev) { $prevSeen[$k] } else { $state.threads[$k].lastComment }
        head        = $state.threads[$k].head
        title       = $state.threads[$k].title
    }
}
# Rewinding lastComment alone does nothing: the fresh ETag would make the retry come back 304,
# the run would log "nothing new (cached)" and the event we meant to retry would be lost for
# good. Drop the validators of the rewound threads only, so exactly those refetch in full.
foreach ($u in $state.etags.Keys) {
    $keep = $true
    foreach ($k in $rewound) {
        if ($u -match "/(issues|pulls)/$k(/|\?|$)") { $keep = $false; break }
    }
    if ($keep) { $statePreEvent.etags[$u] = $state.etags[$u] }
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

# Plain `claude -p` prints nothing until it is completely done, which makes a long run look like
# a hang. --output-format stream-json emits an event per step, so the log carries a live trail of
# what it is doing (tail watch.log to watch it think). The raw stream is kept for forensics.
$rawLog = Join-Path $WatchDir "run_$stamp.jsonl"

# See $SubscriptionOnly above: blank these for the child process so an API key sitting in the
# environment (from a shell profile, a machine-wide setx, another tool) cannot silently move a
# job that fires every $IntervalMin minutes onto a metered bill. This process is one-shot, so
# there is nothing to restore.
if ($SubscriptionOnly) {
    $env:ANTHROPIC_API_KEY       = $null
    $env:ANTHROPIC_AUTH_TOKEN    = $null
    $env:ANTHROPIC_BASE_URL      = $null
    $env:CLAUDE_CODE_USE_BEDROCK = $null
    $env:CLAUDE_CODE_USE_VERTEX  = $null
}

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
                    # On a subscription total_cost_usd is what the same tokens WOULD have cost on
                    # the metered API, not a charge. Read bare, that number looks like a bill.
                    'result' {
                        $costNote = if ($SubscriptionOnly) { ' equiv. API, not billed on a subscription' } else { '' }
                        Write-Log "   == $($o.subtype) (turns: $($o.num_turns), cost: $([math]::Round($o.total_cost_usd,3)) USD$costNote)"
                    }
                    'rate_limit_event' {
                        $ri = $o.rate_limit_info
                        Write-Log "   !! Rate limit event (status: $($ri.status), overage: $($ri.overageStatus), isUsingOverage: $($ri.isUsingOverage), resetsAt: $($ri.resetsAt))"
                        # If this ever prints, the run has spilled past the plan onto paid extra
                        # usage: real money, per token. Loud on purpose.
                        if ($ri.isUsingOverage) { Write-Log '   !! WARNING: paid extra usage (overage) is active. Turn it off at claude.ai -> Settings -> Billing.' }
                    }
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
    Write-Log "RATE LIMIT hit! Resets at Unix timestamp $rateLimitResetsAt - rewinding state and postponing."
    $statePreEvent | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8

    $epoch = [datetime]'1970-01-01T00:00:00Z'
    $resetUtc = $epoch.AddSeconds($rateLimitResetsAt)
    $newStart = $resetUtc.ToLocalTime().AddMinutes(5)

    $newStart.ToString('o') | Set-Content -Path $PostponeFile -Encoding utf8
    Write-Log "Runs will be skipped until $($newStart.ToString('yyyy-MM-dd HH:mm:ss')) via $PostponeFile (the scheduler keeps firing every $IntervalMin min; each run just no-ops until then)."

    Show-Toast $ProjectLabel "Claude hit a rate limit. Skipping runs until $($newStart.ToString('yyyy-MM-dd HH:mm'))" | Out-Null
    exit 0
}

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $draft)) {
    Write-Log "FAILED run (exit $LASTEXITCODE, report: $(Test-Path $draft)) - rewinding state so the next run retries"
    $statePreEvent | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8
}

# --- notify -------------------------------------------------------------------------------
$latestPath = Join-Path $WatchDir 'LATEST.md'
if (Test-Path $draft) {
    Write-Log "REPORT: $draft"
    Copy-Item $draft $latestPath -Force

    $gist = (Get-Content $draft | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' } |
             Select-Object -First 1)
    if (-not $gist) { $gist = "See $latestPath" }

    $acted = $gist -match '^\s*ACTION'
    $head  = if ($acted) { "$ProjectLabel : published ($authors)" }
             else        { "$ProjectLabel : activity, no action ($authors)" }

    $gist = $gist -replace '^\s*(NO ACTION|ACTION)\s*:\s*', ''
    if ($gist.Length -gt 160) { $gist = $gist.Substring(0, 160) + '...' }

    Write-Log ("Verdict: " + $(if ($acted) { 'ACTED' } else { 'no action' }) + " - $gist")
    Show-Toast $head "$gist -- details in $latestPath" | Out-Null
}
else {
    Write-Log 'WARN: Claude ran but produced no report file.'
    Show-Toast "$ProjectLabel : activity" `
               "$($events.Count) event(s) ($authors), but no report. Check GitHub and watch.log" | Out-Null
}

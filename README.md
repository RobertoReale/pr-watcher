# pr-watcher

A generic engine that watches a GitHub conversation (a repo, a seed list of PRs/issues, plus
whatever notifications and discovery search turn up) and wakes Claude Code headless to analyse
anything new and, if it's genuinely your turn to move, act on it: comment, and optionally push
and open PRs, depending on the tools you grant it.

It grew out of a single-purpose watcher for one PR negotiation and was split into a reusable
engine so any future project can reuse the plumbing (polling, ETag caching, state, drafts,
Windows toast notifications, self-retirement) without rewriting it, by only writing two files:
a config and a project brief.

## How it decides what to do

1. **Polling (the spine)** - for every thread it knows about, it fetches comments and (for PRs)
   the head SHA. Conditional requests (ETags) mean a thread with no activity costs a 304, not a
   full request, so watching more threads does not cost more API quota.
2. **Notifications** - `/notifications?all=true`, so already-read threads still count.
3. **Discovery search** - your own search queries, to catch a thread nobody pinged you on.

Every run that finds nothing new exits without spending anything. Only a real event wakes
Claude, which always leaves a written report before doing anything else, so you can review or
undo what it published.

## Setup

Fastest path - run the wizard:

```
pwsh -File init.ps1
```

It asks the handful of questions this needs answered (repo, GitHub user, seed threads, where the
brief lives - offering to create a blank one for you - working directory, poll interval, how
much autonomy to grant), and writes the config JSON for you. Then:

```
pwsh -File engine\watch.ps1 -ConfigPath your.config.json -WhatIf      # dry run, no side effects
pwsh -File engine\watch.ps1 -ConfigPath your.config.json -TestToast   # check notifications
pwsh -File engine\watch.ps1 -ConfigPath your.config.json -Install     # start watching for real
```

Before that last step, fill in the brief the wizard created for you (or your own):
what the mission is, what's been said so far, what counts as "our turn to move" for this
specific case, and any project-specific rules of evidence/voice. The engine only encodes the
generic gates (see `engine/prompt.template.txt`); everything mission-specific belongs in the
brief, which Claude reads before deciding anything.

Manual path (skip the wizard): copy `examples/example.config.json`, fill in the fields yourself
(see the table below), and run the same three commands. Either way, make sure a GitHub token is
available where the config's `tokenEnvVar` (default `GH_TOKEN`) points, with enough scope to
read the repo and, if you grant those tools, comment/push.

On Windows, `-Install` registers a Task Scheduler task marked **Interactive** (logon-triggered),
required for the toast to show at all. On Linux, it registers a `systemctl --user` timer, and
toasts use `notify-send` if installed.

## Config fields

| field | required | meaning |
|---|---|---|
| `projectLabel` | yes | shown in toasts/logs |
| `repo` | yes | `owner/name` being watched |
| `githubUser` | yes | whose voice/account this acts as |
| `seedThreads` | yes | PR/issue numbers to start watching |
| `briefPath` | yes | the project-specific context file Claude reads first |
| `projectDir` | yes | working directory `claude -p` is launched from |
| `taskName` | yes | Windows scheduled task name |
| `watchDir` | no | defaults to `%LOCALAPPDATA%\pr-watch\<taskName>` |
| `intervalMinutes` | no | default 20 |
| `discoveryQueries` | no | GitHub search queries; omit/empty to skip that source |
| `mainPR` | no | if set, the watcher retires `graceDays` after this PR closes |
| `graceDays` | no | default 14 |
| `endOfMissionReminder` | no | text added to the end-of-mission report |
| `tokenEnvVar` | no | default `GH_TOKEN` |
| `tokenFile` | no | fallback file with a `GITHUB_TOKEN: <token>` line |
| `allowedTools` | no | Claude Code `--allowedTools` list; default is read+comment, no push |
| `promptTemplate` | no | defaults to `engine/prompt.template.txt` |

## Commands

- `-WhatIf` - report what it would do; never launches Claude, never writes state.
- `-Reset` - forget all state and re-baseline from scratch.
- `-Install` - register the scheduled task.
- `-Uninstall` - remove it.
- `-TestToast` - fire a sample notification to prove the channel works.

## Notes

- Keep `engine/watch.ps1` pure ASCII: Windows PowerShell 5.1 (used only for the toast) reads
  `.ps1` files as ANSI, and non-ASCII characters corrupt the parse.
- Never commit a config file that embeds a real token. Use `tokenEnvVar` or a token file kept
  outside this repo.

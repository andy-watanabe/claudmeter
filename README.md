# ClaudeMeter

A menu bar readout of how much of your monthly Claude **extra-usage cap** is left.
Native Swift, no dependencies, no network, no credentials.

## What the number means — read this first

It is **not** your total monthly token allowance.

Your account is on an **Enterprise** plan. The usage API reports no 5-hour or weekly
rate-limit windows for this seat — on Enterprise those are administered org-side and
aren't exposed per user. The single meter it does report is **extra usage**: the
pay-as-you-go spend that applies *on top of* whatever your seat includes, capped at
$50/month.

In practice, on this seat, **the $50 appears to be the whole budget.** Evidence: on
the first-ever day of use, extra usage was already accruing 16 minutes after the
desktop app started logging (`xu = 0.8` at 10:18, from a 10:02 start). Had there been
an included allowance, usage would have drawn from that first and `xu` would have
stayed at zero until it was exhausted. That, plus the empty `windows`, points to a
seat where every request meters straight against the $50 cap.

So the menu bar number is effectively "how much of this month's Claude budget is
left" — the ceiling where Claude stops until the cap resets or an admin raises it.
Confirm the arrangement with your workspace admin; it can't be read authoritatively
from this machine.

## Where the data comes from

`~/Library/Application Support/Claude/plan-usage-history.json` — the sample log
Claude Desktop appends to every ~15 minutes. ClaudeMeter reads it directly and
watches it for changes, so it updates as soon as the desktop app records a new
sample.

**This means the reading only advances while Claude Desktop is running.** If the
last sample is more than 45 minutes old, the dot turns hollow (`◌`) and the menu
says the data is stale.

## Display

- `● 90%` — percent of the extra-usage cap remaining
- White/black at >25% left, orange at ≤25%, red at ≤10%
- `◌` instead of `●` means the data is stale

Click for the dollar figure, the last-updated time, Refresh Now, and a
**Start at Login** toggle.

## Config

The dollar ceiling isn't recorded on disk anywhere, so it's set here:

```
~/.config/claude-meter/config.json
```

```json
{ "monthlyLimitUSD": 50 }
```

Defaults to 50 if the file is absent. The *percentage* is read from the log and is
correct regardless — only the dollar readout depends on this value.

## Build / install

```bash
./build.sh
cp -R ClaudeMeter.app ~/Applications/
```

## Check the numbers from a terminal

```bash
~/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --dump
```

## Uninstall

Quit from the menu, untick Start at Login first (or delete
`~/Library/LaunchAgents/com.local.claudemeter.plist`), then remove
`~/Applications/ClaudeMeter.app`.

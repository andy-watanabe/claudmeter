# ClaudeMeter

A menu bar readout of how much of your monthly Claude **extra-usage cap** is left.
Native Swift, no dependencies, no network, no credentials.

## Install

**Requires:** macOS, [Claude Desktop](https://claude.ai/download) installed and
signed in, and the Xcode Command Line Tools (`xcode-select --install` if you don't
already have them — most developer machines do).

```bash
curl -fsSL https://raw.githubusercontent.com/andy-watanabe/claudmeter/main/install.sh | bash
```

This builds the app from source and launches it — nothing is downloaded as a
prebuilt binary. Re-run the same command any time to update to the latest version.

If your Mac won't run a piped script, clone and run it locally instead:

```bash
git clone https://github.com/andy-watanabe/claudmeter.git
cd claudmeter
./install.sh
```

**No data yet after installing?** The menu shows "No usage data yet" until Claude
Desktop writes its first sample, which happens every ~15 minutes. Leave Claude
Desktop open for a bit, or click the menu bar icon → Refresh Now.

## What the number means — read this first

It is **not** your total monthly token allowance.

Your account is on an **Enterprise** plan. The usage API reports no 5-hour or weekly
rate-limit windows for this seat — on Enterprise those are administered org-side and
aren't exposed per user. The single meter it does report is **extra usage**: the
pay-as-you-go spend that applies *on top of* whatever your seat includes, capped at
$50/month.

On at least one seat in this org, **the $50 appeared to be the whole budget** —
extra usage was already accruing within 16 minutes of that account's first-ever
session, which is what you'd expect if there's no included allowance underneath it
sitting between $0 and the cap first. That's one data point, not a guarantee for
every seat — plan configuration can vary by account. Check your own menu (or ask
your workspace admin) rather than assuming your seat works the same way.

Either way, the menu bar number is "how much of the extra-usage cap is left" — the
ceiling where Claude stops until it resets or an admin raises it. Whether that cap
is your *entire* monthly budget or sits on top of an included allowance is a
per-seat question your workspace admin can answer authoritatively; this app can't.

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

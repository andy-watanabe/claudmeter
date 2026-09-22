# ClaudeMeter

A menu bar readout of how much of your monthly Claude **extra-usage cap** you've
used, plus a pace estimate — are you trending to land over or under it by the time
the cycle resets. Native Swift, no dependencies, no network, no credentials.

**macOS only.** This is a menu bar app built on Cocoa/`NSStatusBar` — that concept
doesn't exist on Windows, so there's no version of this for a PC.

## Install

**Requires:** macOS, [Claude Desktop](https://claude.ai/download) installed and
signed in, and the Xcode Command Line Tools (`xcode-select --install` if you don't
already have them — most developer machines do).

### Homebrew (recommended)

```bash
brew tap andy-watanabe/claudmeter
brew install claudemeter
claudemeter &
```

Builds from source at install time (no prebuilt binary is shipped), and `brew
upgrade` pulls future updates. On first tap/install, Homebrew will ask you to run
`brew trust andy-watanabe/claudmeter` — that's expected for any third-party tap,
not specific to this one.

`claudemeter &` starts it for the current session. To keep it running after you
log in again, launch it once, click the menu bar icon, and toggle **Start at
Login** from its menu.

### Without Homebrew

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

- The Claude mark + `10%` — percent of the extra-usage cap **used**. The mark is
  extracted live from your locally installed Claude Desktop app's icon (never
  bundled by ClaudeMeter itself) as a **template image**, so macOS auto-tints it
  to match your menu bar's own text color automatically, in any theme — the same
  mechanism behind most other menu bar icons.
- The `10%` text turns orange at ≥75% used and red at ≥90%; the icon stays
  neutral (that's what "template" means) and carries no color of its own.
- The whole thing fades to half-opacity when the data is stale (no fresh sample
  in 45+ minutes) — check that Claude Desktop is running.

Click for the dollar figure, then a two-line pace readout:

- **Verdict line** — 🔺 trending over the cap (with roughly how many days until it
  hits), ⚠️ cutting it close, or ✅ trending under it — each with the projected
  percent (or day count) that backs it up
- **Rate line** — percent-of-cap consumed per day, and days left in the cycle

For the full breakdown (which rate window was used, the exact exhaustion date,
etc.), run `--dump` from a terminal (below) rather than the menu — the menu is
kept to the two lines above on purpose.

Also shown: the last-updated time, Refresh Now, and a **Start at Login** toggle.

### How the pace estimate works

The rate is the higher of two numbers: the average since the start of the current
cycle, and the rate over just the last 3 hours. Using the higher of the two is
deliberate — a quiet afternoon right after a heavy morning shouldn't make a real
trend disappear from the display. The cycle is assumed to reset on the calendar
month unless you set `cycleLengthDays` in the config file (below) to use a rolling
window instead.

**Early in a cycle, with only a few samples, this projection can swing hard** — a
single burst of usage early on can extrapolate into a scary-looking projected
percentage. It gets more stable as more of the cycle's actual history accumulates.
Treat it as a trend signal, not a forecast to the decimal point.

### Refresh rate

The menu refreshes every 60 seconds, and also instantly whenever Claude Desktop
actually writes a new sample (via a file watch, not polling). Going faster than
60s wouldn't show you anything newer — Claude Desktop itself only writes a new
sample roughly every 15 minutes, so that's the real ceiling on freshness no matter
how often this app checks. The 60s timer only exists as a backstop in case a
write is missed; reading a ~1-2KB JSON file that often has no measurable effect
on CPU or battery.

## Config

The dollar ceiling isn't recorded on disk anywhere, so it's set here:

```
~/.config/claude-meter/config.json
```

```json
{ "monthlyLimitUSD": 50, "cycleLengthDays": 30 }
```

`monthlyLimitUSD` defaults to 50 if the file is absent — the *percentage* is read
from the log either way and is correct regardless; only the dollar readout depends
on this value. `cycleLengthDays` is optional: omit it to assume a calendar-month
reset (the default), or set it if your cap actually resets on a rolling N-day window
instead.

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

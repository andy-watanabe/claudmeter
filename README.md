# ClaudeMeter

A menu bar readout of how much of your Claude usage limits you've used — the
monthly **extra-usage cap**, or the **5-hour / 7-day windows**, whichever your org
reports — plus a pace estimate: are you trending to land over or under the limit by
the time it resets. Native Swift, no dependencies, no network, no credentials.

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

**What gets reported depends on the org.** Claude Desktop logs one or more meters
per sample, each a percent used:

| Key | Shown as | Resets | Notes |
|---|---|---|---|
| `xu` | Extra usage | Billing cycle (calendar month, or `cycleLengthDays`) | Pay-as-you-go spend on top of what the seat includes |
| `fh` | 5-hour window | ~5h after the window starts | Inferred, not documented |
| `sd` | 7-day window | ~7d after the window starts | Inferred, not documented |

One Enterprise org reported only `xu`; another reports only `fh` and `sd`. When
`xu` is present it's the headline; otherwise the 7-day window is (it's the one that
can lock you out for days); failing both, whichever meter is furthest along. When
there's more than one meter, **Show in Menu Bar** in the menu lets you pick which one
the menu bar shows; the choice sticks across restarts. Unknown keys are shown as-is, with no pace estimate.

**Budgets are per org, and so is the display.** The log is shared across orgs — if
you switch, new samples just carry a different `org` ID. ClaudeMeter only reads
samples from the org Claude Desktop most recently logged, and shows that org's
short ID in the menu.

The rest of this section is about the extra-usage meter.

**The actual dollar cap varies by seat** — it isn't a fixed org-wide number, so
ClaudeMeter never shows one (see below for why it can't, even if it wanted to).
Check Claude Desktop's own menu bar item for your specific figure, or ask your
workspace admin.

Either way, the percentage ClaudeMeter shows is "how much of *your* extra-usage
cap is used" — the ceiling where Claude stops until it resets or an admin raises
it. Whether that cap is your entire monthly budget or sits on top of an included
allowance is a per-seat question your workspace admin can answer authoritatively;
this app can't.

## Where the data comes from

`~/Library/Application Support/Claude/plan-usage-history.json` — the sample log
Claude Desktop appends to every ~15 minutes. ClaudeMeter reads it directly and
watches it for changes, so it updates as soon as the desktop app records a new
sample.

**Most samples carry no figure.** Claude Desktop writes an entry every ~15
minutes, but usually with an empty payload; an actual percentage lands every
1–2.5 hours. So "Claude Desktop stopped writing" and "the figure hasn't changed
yet" are different things, and ClaudeMeter treats them differently:

| What's happening | What you see |
|---|---|
| Normal — polling, figure current | Nothing; just the figure's timestamp |
| Polling fine, but no new figure in 4h+ | A quiet note that Claude hasn't reported one |
| No sample at all in 45min+ | ⚠︎ warning that Claude Desktop isn't logging, and the display dims |

Only the last case means something is actually wrong. The reading only advances
while Claude Desktop is running.

## Display

- The Claude mark + `10% mo` — percent of the headline meter **used**, plus a tag
  for which limit it is: `mo` for the monthly extra-usage cap (or `30d` if you set
  `cycleLengthDays`), `5h` or `7d` for the windows. Orgs differ, so the number alone
  could be read as a monthly budget when it's really a 5-hour window. The mark is
  extracted live from your locally installed Claude Desktop app's icon (never
  bundled by ClaudeMeter itself) as a **template image**, so macOS auto-tints it
  to match your menu bar's own text color automatically, in any theme — the same
  mechanism behind most other menu bar icons.
- The `10%` text turns orange at ≥75% used and red at ≥90%; the icon stays
  neutral (that's what "template" means) and carries no color of its own.
- The whole thing fades to half-opacity only when Claude Desktop has stopped
  writing to the log entirely (see the table above) — a figure that simply
  hasn't moved yet is still the correct current value, so it isn't dimmed.

Click for the menu. The top line says what kind of limits your org has, e.g.
"Limits: 5-hour + 7-day windows (no monthly budget)" or "Limits: monthly cap".
Below that, every meter's percent used, then a two-line pace readout:

- **Verdict line** — 🔺 trending over the limit (with roughly how long until it
  hits), ⚠️ cutting it close, or ✅ trending under it — each with the projected
  percent (or time left) that backs it up
- **Rate line** — percent used per day (per hour for the windows), and time until
  the reset

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

For the 5-hour and 7-day windows, the reset isn't in the log, so it's estimated:
the first figure after the last drop to a lower value marks the window's start,
and the reset is 5h (or 7d) after that. It can run late by up to one gap between
figures. Once that estimated reset has passed, the menu says the window may have
reset and waits for a new figure instead of projecting from a stale one.

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

```
~/.config/claude-meter/config.json
```

```json
{ "cycleLengthDays": 30 }
```

Optional and rarely needed: omit it to assume a calendar-month reset (the
default, and the one confirmed correct by Claude Desktop's own popover saying
"resets Oct 1"), or set it if your cap actually resets on a rolling N-day window
instead.

**There's no dollar-amount setting**, on purpose. An earlier version asked you to
manually enter your cap's dollar value here, because that figure isn't recorded
anywhere in Claude Desktop's local data — confirmed by searching its entire
`Application Support` directory, including the Electron `IndexedDB`/`Local
Storage` caches an app like this would normally use, and finding nothing. The
only place it exists is behind Anthropic's own authenticated API — the same one
powering Claude Desktop's native usage popover. Reading it would require either
extracting Claude Desktop's session credentials to call an undocumented
endpoint, or scraping its UI via the Accessibility API; both are a bigger, more
fragile step than a menu bar percentage indicator should take. So instead of
asking you to babysit a number the app couldn't verify, ClaudeMeter just doesn't
show one — the percentage needs no configuration and is always correct, straight
from Claude Desktop's own log.

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

# ClaudeMeter

A macOS menu bar app that shows how much of your Claude usage limits you've used,
read from Claude Desktop's own local log. Single file: `main.swift`.

## If someone asked you to set ClaudeMeter up for them

They may not be technical. Talk plainly, do the work yourself, and only ask them
to act when a step needs their hands (a system dialog, a password, a click).

1. **Check it's a Mac.** This is macOS-only. On anything else, say so and stop.
2. **Check Claude Desktop.** It must be installed (`/Applications/Claude.app`) and
   signed in. ClaudeMeter reads
   `~/Library/Application Support/Claude/plan-usage-history.json`, which Claude
   Desktop writes. If that file is missing, Claude Desktop hasn't logged anything
   yet: have them open it, sign in, and leave it running. The first figure can
   take up to ~15 minutes.
3. **Check the Swift compiler:** `command -v swiftc`. If it's missing, run
   `xcode-select --install`. That opens a macOS dialog: tell them to click
   Install and wait (several minutes), then continue. Don't try to work around it.
4. **Install:** run `./install.sh` from this repo. It builds the app, copies it to
   `~/Applications/ClaudeMeter.app`, and launches it. If it fails, read the error,
   fix the cause, and retry.
5. **Read their numbers:**
   `~/Applications/ClaudeMeter.app/Contents/MacOS/ClaudeMeter --dump`
6. **Explain them** (see below), then point out two things in the menu: **Start at
   Login** (so it survives a restart) and, if they have more than one meter,
   **Show in Menu Bar** (to pick which one the menu bar shows).

To update later: `git pull && ./install.sh` in this folder.

## Explaining someone's numbers

Explain the limits *they* have, from their `--dump` output. Orgs differ, so never
assume. The `Limits:` line says what their org reports:

| Key | Menu bar tag | What it is | Resets |
|---|---|---|---|
| `xu` | `mo` | Extra usage: a monthly cap on pay-as-you-go spend | Start of each calendar month, unless `cycleLengthDays` is set |
| `fh` | `5h` | A short rolling limit | About 5 hours after the window starts |
| `sd` | `7d` | A weekly rolling limit | About 7 days after the window starts |

Cover, in plain words:

- **What they have.** A monthly cap, 5-hour + 7-day windows, or both. If there's
  no `xu`, say clearly that there's no monthly budget in the data — people often
  assume there is one.
- **Where they are.** Percent used, and the verdict line (✅ under, ⚠️ close,
  🔺 over).
- **When it resets.** From the `projected:` line.
- **What 100% means.** They can't send more messages until that limit resets.
  If their org has extra usage turned on, they may be able to keep going and be
  billed instead. For `xu` itself, 100% means the extra-usage spend is used up
  until the month resets or an admin raises the cap.

Be honest about what's uncertain:

- `fh`/`sd` are **inferred**, not documented by Anthropic. `fh` behaves like a
  5-hour window. `sd` has been seen dropping to 0 overnight, which doesn't fit a
  true 7-day window, so its reset time is a best guess.
- ClaudeMeter can't show a dollar amount. That figure isn't stored anywhere on
  the Mac. Claude Desktop's own usage popover, or their admin, has it.
- The pace estimate swings early in a cycle. It's a trend, not a forecast.

## Uninstall

Untick **Start at Login** in the menu (or delete
`~/Library/LaunchAgents/com.local.claudemeter.plist`), quit from the menu, then
delete `~/Applications/ClaudeMeter.app`. Homebrew installs: `brew uninstall
claudemeter`.

## Working on the code

- Build: `./build.sh`. Install locally: `./install.sh`.
- Test against a fixture log instead of the real one:
  `CLAUDEMETER_LOG_PATH=/path/to/fixture.json ClaudeMeter.app/Contents/MacOS/ClaudeMeter --dump`.
  Real logs take hours to reach interesting states.
- Release: `./release.sh` builds a universal, ad-hoc signed `dist/ClaudeMeter.zip`;
  attach it to a GitHub release with `gh release create vX.Y.Z dist/ClaudeMeter.zip`.
  Then bump `url` and `sha256` in the Homebrew formula (repo
  `andy-watanabe/homebrew-claudmeter`, `Formula/claudemeter.rb`) to the new tag.
- Never bundle Anthropic's logo or mascot. The menu bar mark is extracted at
  runtime from the user's installed Claude Desktop.

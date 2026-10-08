# Sprout

A macOS menu bar app: a pixel critter whose body fills as the Mac gets busier,
plus a menu that says what's loading the Mac, tracing busy processes back to the
Claude Code session and project that started them. Single file: `main.swift`.

## If someone asked you to set Sprout up for them

They may not be technical. Talk plainly, do the work yourself, and only ask them
to act when a step needs their hands (a system dialog, a password, a click).

1. **Check it's a Mac.** This is macOS-only. On anything else, say so and stop.
2. **Check the Swift compiler:** `command -v swiftc`. If it's missing, run
   `xcode-select --install`. That opens a macOS dialog: tell them to click
   Install and wait (several minutes), then continue. Don't try to work around it.
3. **Install:** run `./install.sh` from this repo. It builds the app, copies it to
   `~/Applications/Sprout.app`, and launches it. It also replaces ClaudeMeter
   (Sprout's old name) if it's there, keeping Start at Login. If it fails, read
   the error, fix the cause, and retry.
4. **Read the Mac's state:** `~/Applications/Sprout.app/Contents/MacOS/Sprout --dump`
5. **Explain it** (see below), then point out **Start at Login** in the menu, so
   Sprout survives a restart.

To update later: `git pull && ./install.sh` in this folder.

## Explaining the Mac's state

From the `--dump` output, in plain words:

- **The level and number.** It's the worst of CPU, memory pressure, and heat, so
  say which one is driving it. Calm under 40, Busy to 75, Strained to 90,
  Overloaded above. Sprout pants at Strained, and sweats and runs at
  Overloaded (faster the harder the Mac works).
- **CPU line.** "N tasks for M cores": more tasks than cores means work is
  queuing, which is what makes the Mac feel sluggish.
- **Memory line.** Pressure "high" or "critical" means the Mac is swapping to
  disk; that slows everything even with idle cores. Swap that's nearly full is
  worth a mention, but it's pressure that matters day to day.
- **Busiest.** Name the culprits. "Claude · session title: command" rows are
  work that Claude Code session started. Several test runs or builds at
  once is the common cause; suggest capping workers (`vitest --maxWorkers=2`,
  `jest --maxWorkers=2`, `pytest -n 2`) or running them one at a time.
- **Claude Code sessions.** Claude Desktop keeps sessions running after you
  leave them, so the count is usually higher than what someone's using. Point
  out idle ones (they can archive them in Claude Desktop), "running twice"
  (one copy is left over), and ⚠︎ commands running over an hour (usually a stuck
  wait loop; they can Stop it from the menu).
- Security agents (ThreatLocker, Kandji, CrowdStrike and the like) often show
  up; they're managed by IT and can't be turned off.

## Uninstall

Untick **Start at Login** in the menu (or delete
`~/Library/LaunchAgents/com.local.sprout.plist`), quit from the menu, then
delete `~/Applications/Sprout.app`. Homebrew installs: `brew uninstall sprout`.

## Working on the code

- Build: `./build.sh`. Install locally: `./install.sh`.
- `--dump` prints the menu's lines; use it to check changes without the GUI.
- Release: `./release.sh` builds a universal, ad-hoc signed `dist/Sprout.zip`;
  attach it to a GitHub release with `gh release create vX.Y.Z dist/Sprout.zip`.
  Then bump `url` and `sha256` in the Homebrew formula (repo
  `andy-watanabe/homebrew-sprout`, `Formula/sprout.rb`) to the new tag.
- Sprout is drawn in code (`sproutPixels` in `main.swift`), no image files. Its
  body fills from the bottom with `MacLoad.score`. At 75 it turns orange,
  droops, and pants; at 90 it turns red, drips sweat, and runs in place, the
  stride faster with `MacLoad.runIntensity` (`strainFrame(tick:running:)`;
  the frame timer only runs while strained). Color only
  appears when strained, so it always means something's wrong. Status item
  updates are skipped when nothing changed, since each one makes macOS redraw.
  Never bundle or copy Anthropic's logo or mascot (including Clawd).
- Sessions are identified by `--resume`/`--session-id` in the process's
  arguments, or else by the scratch folder Claude Code creates (named after the
  session ID) within a second of the process starting. Titles and last activity
  come from the transcript in `~/.claude/projects`. Never read other processes'
  environment: it holds Claude login tokens.
- Stop (`stopCommand`) only ever targets a shell whose parent is a Claude Code
  session, re-checked against a fresh process list, and always confirms first.
- Sprout used to be ClaudeMeter (Claude usage limits from Claude Desktop's log).
  That code is gone; the last version is tag `v1.5.0`.

# Sprout

A little critter in your Mac's menu bar that shows how hard your Mac is working,
and what's making it work, down to which Claude Code session and project.

<img src="docs/menubar.png" alt="Sprout in the menu bar, orange and at 80% while the Mac is strained" width="70">

Sprout's body fills up as your Mac gets busier. When the Mac is strained, Sprout
turns orange and pants. When it's overloaded, it turns red, sweats, and runs, faster
the harder the Mac is working. Everything is read from your own Mac: nothing is
sent anywhere, and it needs no password or API key.

**Needs:** a Mac.

## Get it running

Pick one.

### Option 1: Ask Claude to set it up

If you have Claude Code (in the terminal, or the Code tab in Claude Desktop),
paste this in:

```text
Clone https://github.com/andy-watanabe/sprout into ~/sprout, read its CLAUDE.md,
and follow it to set Sprout up for me. Then tell me how my Mac is doing.
```

Claude installs any missing tools, builds the app, starts it, and tells you
what's loading your Mac. If something goes wrong, it fixes it.

### Option 2: Download the app

1. Download [Sprout.zip](https://github.com/andy-watanabe/sprout/releases/latest/download/Sprout.zip)
   and double-click it to unzip.
2. Drag **Sprout** into your **Applications** folder, and open it.
3. macOS will say it can't verify the app. That's because it isn't signed by a
   paid Apple developer account, not because anything is wrong with it. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down, and
   click **Open Anyway** next to Sprout. You only do this once.
4. Click Sprout in the menu bar and turn on **Start at Login**.

To update, download it again and replace the old copy.

### Option 3: Homebrew or script (for developers)

```bash
brew tap andy-watanabe/sprout
brew install sprout
sprout &
```

Or, without Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/andy-watanabe/sprout/main/install.sh | bash
```

Both build from source, which needs the Xcode Command Line Tools
(`xcode-select --install`). Re-run the script, or `brew upgrade`, to update.

**Coming from ClaudeMeter?** Sprout is its new name. The install script replaces
ClaudeMeter and keeps your Start at Login setting.

## Reading it

The number is how hard your Mac is working, 0–100%. It's whichever is worst right
now: CPU, memory, or heat. Any one of them maxed out is enough to make the Mac
feel slow.

| Level | Load | Sprout |
|---|---|---|
| Calm | under 40% | Fidgets: blinks, scratches its head, looks around |
| Busy | 40–75% | Same, just fuller |
| Strained | 75–90% | Turns orange, droopy eyes, pants (bobs about once a second) |
| Overloaded | 90%+ | Turns red, sweats, and runs in place: the busier the Mac, the faster it runs |

macOS mutes colors in the menu bar, so the orange and red look softer there than
you might expect; the movement is the louder signal.

**Click Sprout** for the details:

- **CPU:** how busy, and how many tasks are queued for your cores. More tasks
  than cores means work is waiting its turn.
- **Memory:** macOS's memory pressure, and how much swap (disk standing in for
  RAM) is in use.
- **Busiest:** the top things using CPU, grouped by app. Work started by Claude
  Code is traced back to its session, e.g. "Claude · Canvas catalog: npm exec
  vitest run · 3.0 cores". Hover it to **Stop** that command.
- **Most memory.**
- **Claude Code sessions:** every session running on your Mac, by its title, with
  whether it's active or how long it's been idle. Claude Desktop keeps sessions
  running after you leave them, so this is usually more than you're using.
  "Running twice" means two copies of one session; one is left over. Hover a
  session to see what it's running and **Stop** any of it. ⚠︎ marks a command
  running for over an hour, which is usually a wait loop or a run that hung.

  Stop always asks first. It ends that one command (Claude sees it finish), not
  the session. To close a session itself, archive it in Claude Desktop.
- **Start at Login**, **Animate Sprout** (untick to keep it still, color and all
  else unchanged; it also stays still if Reduce Motion is on), **Quit**.

Sprout itself uses next to nothing: a few cheap system reads every 5 seconds, and
it only lists processes when you open its menu. Panting costs about 1% of one
core, and only runs while the Mac is strained.

## Taming a busy Mac

The usual culprit with several Claude Code sessions is test runners and builds
running at the same time. Each one tries to use every core, so two or three at
once swamp the machine. Capping each run helps a lot, e.g. `vitest run
--maxWorkers=2`, `jest --maxWorkers=2`, or `pytest -n 2`.

## Uninstall

Turn off **Start at Login** in the menu, click **Quit**, then delete Sprout from
your Applications folder (or `~/Applications`). Homebrew: `brew uninstall sprout`.

## Check from a terminal

```bash
~/Applications/Sprout.app/Contents/MacOS/Sprout --dump
```

Prints the same lines as the menu.

## History

Sprout started as ClaudeMeter, a readout of Claude usage limits from Claude
Desktop's local log. In October 2026 Claude Desktop stopped checking usage in
the background unless its own menu bar panel is opened daily, so those figures
went stale. The last ClaudeMeter version is tagged
[`v1.5.0`](https://github.com/andy-watanabe/sprout/releases/tag/v1.5.0).
Build and release steps are in [CLAUDE.md](CLAUDE.md).

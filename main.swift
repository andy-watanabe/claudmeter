import Cocoa

// ClaudeMeter — a menu bar readout of how much of the monthly Claude extra-usage cap is left.
//
// NOTE: "extra usage" is pay-as-you-go spend on TOP of whatever the plan includes.
// It is not a total token allowance. On this Enterprise seat the API reports no
// rate-limit windows at all, so included capacity is not visible from this machine.
//
// Data source: ~/Library/Application Support/Claude/plan-usage-history.json, the
// sample log Claude Desktop appends to every ~15 minutes. Read-only, no credentials,
// no network. Each sample looks like:
//   {"t": <epoch ms>, "org": "<uuid>", "u": {"xu": 9.52}}
// where "u" carries percent-used figures and is often empty (nothing new that poll),
// so we walk backwards for the most recent sample that actually reported something.

let usageLogPath = NSString(string: "~/Library/Application Support/Claude/plan-usage-history.json")
    .expandingTildeInPath
let configPath = NSString(string: "~/.config/claude-meter/config.json").expandingTildeInPath

/// Claude Desktop polls roughly every 15 minutes; past this we stop trusting the number.
let stalenessThreshold: TimeInterval = 45 * 60

// MARK: - Model

struct Reading {
    /// Percent *used* per meter, keyed as the log keys them ("xu" = extra usage).
    var meters: [String: Double]
    var sampledAt: Date

    /// The headline meter. Extra usage is the only meter reported on Enterprise seats;
    /// otherwise fall back to whichever meter is furthest along.
    var headline: (key: String, percentUsed: Double)? {
        if let xu = meters["xu"] { return ("xu", xu) }
        guard let worst = meters.max(by: { $0.value < $1.value }) else { return nil }
        return (worst.key, worst.value)
    }

    var isStale: Bool { Date().timeIntervalSince(sampledAt) > stalenessThreshold }
}

func label(forMeterKey key: String) -> String {
    // Only "xu" is a key we've actually observed; anything else is shown as-is
    // rather than guessed at.
    key == "xu" ? "Extra usage" : key
}

// MARK: - Reading the log

func loadReading() -> Reading? {
    guard let data = FileManager.default.contents(atPath: usageLogPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let samples = root["samples"] as? [[String: Any]]
    else { return nil }

    for sample in samples.reversed() {
        guard let raw = sample["u"] as? [String: Any], !raw.isEmpty,
              let millis = sample["t"] as? Double
        else { continue }

        var meters: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? Double { meters[key] = number }
        }
        guard !meters.isEmpty else { continue }

        return Reading(meters: meters, sampledAt: Date(timeIntervalSince1970: millis / 1000))
    }
    return nil
}

/// The dollar ceiling isn't recorded anywhere on disk, so it lives in a config file.
func loadMonthlyLimit() -> Double {
    guard let data = FileManager.default.contents(atPath: configPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let limit = root["monthlyLimitUSD"] as? Double
    else { return 50.0 }
    return limit
}

// MARK: - Login item
//
// A LaunchAgent rather than SMAppService: this app is built locally and unsigned,
// and SMAppService registration is unreliable without a signed bundle.

let launchAgentPath = NSString(string: "~/Library/LaunchAgents/com.local.claudemeter.plist")
    .expandingTildeInPath

func launchesAtLogin() -> Bool { FileManager.default.fileExists(atPath: launchAgentPath) }

func setLaunchAtLogin(_ enabled: Bool) {
    let fm = FileManager.default
    if enabled {
        let executable = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": "com.local.claudemeter",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
        ]
        try? fm.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: launchAgentPath))
        }
    } else {
        try? fm.removeItem(atPath: launchAgentPath)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        refresh()
        startWatching()

        // Backstop for the file watch, and it keeps the "updated N ago" text honest.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Display

    @objc func refresh() {
        let reading = loadReading()
        renderTitle(reading)
        rebuildMenu(reading)
    }

    private func renderTitle(_ reading: Reading?) {
        guard let button = statusItem.button else { return }

        guard let reading, let headline = reading.headline else {
            button.attributedTitle = styled("◌ —", color: .secondaryLabelColor)
            button.toolTip = "No usage figures recorded yet. Claude Desktop writes these every ~15 minutes."
            return
        }

        let remaining = max(0, 100 - headline.percentUsed)
        let color: NSColor = remaining <= 10 ? .systemRed
            : remaining <= 25 ? .systemOrange
            : .labelColor
        let mark = reading.isStale ? "◌" : "●"
        button.attributedTitle = styled("\(mark) \(Int(remaining.rounded()))%", color: color)
        button.toolTip = "\(label(forMeterKey: headline.key)): \(Int(remaining.rounded()))% of extra-usage cap remaining"
    }

    private func styled(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func rebuildMenu(_ reading: Reading?) {
        let menu = statusItem.menu!
        menu.removeAllItems()

        func info(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        guard let reading, let headline = reading.headline else {
            info("No usage data yet")
            info("Claude Desktop records this every ~15 min")
            addControls(to: menu)
            return
        }

        let remaining = max(0, 100 - headline.percentUsed)
        info("\(Int(remaining.rounded()))% of extra-usage cap left")

        let limit = loadMonthlyLimit()
        let spent = limit * headline.percentUsed / 100
        info(String(format: "$%.2f of $%.2f used", spent, limit))

        // Anything beyond the headline meter, shown rather than hidden.
        for (key, used) in reading.meters.sorted(by: { $0.key < $1.key }) where key != headline.key {
            info(String(format: "%@: %.0f%% used", label(forMeterKey: key), used))
        }

        menu.addItem(.separator())

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        info("Updated \(formatter.localizedString(for: reading.sampledAt, relativeTo: Date()))")
        if reading.isStale {
            info("⚠︎ Stale — is Claude Desktop running?")
        }

        addControls(to: menu)
    }

    private func addControls(to menu: NSMenu) {
        menu.addItem(.separator())

        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
            .target = self

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchesAtLogin())
        refresh()
    }

    // MARK: File watching

    /// The log is replaced rather than appended in place, so the watch has to be
    /// re-armed on the descriptor going away.
    private func startWatching() {
        watcher?.cancel()
        watcher = nil

        let fd = open(usageLogPath, O_EVTONLY)
        guard fd >= 0 else {
            // File isn't there yet; the 60s timer will pick it up once it appears.
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.refresh()
            if events.contains(.delete) || events.contains(.rename) {
                // Atomic replace: the old inode is gone, so follow the new one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.startWatching() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

// `--dump` runs the same read path as the menu bar and prints the result, for
// checking the numbers or piping them somewhere else.
if CommandLine.arguments.contains("--dump") {
    guard let reading = loadReading(), let headline = reading.headline else {
        print("no usage data in \(usageLogPath)")
        exit(1)
    }
    let limit = loadMonthlyLimit()
    let remaining = max(0, 100 - headline.percentUsed)
    print(String(format: "remaining:  %.0f%%", remaining))
    print(String(format: "spent:      $%.2f of $%.2f", limit * headline.percentUsed / 100, limit))
    print("headline:   \(label(forMeterKey: headline.key)) (\(headline.key))")
    print("meters:     \(reading.meters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    print("sampled:    \(reading.sampledAt)\(reading.isStale ? "  [stale]" : "")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

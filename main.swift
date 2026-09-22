import Cocoa

// ClaudeMeter — a menu bar readout of how much of the monthly Claude extra-usage cap
// has been used, plus a pace estimate (are you trending over or under the cap).
//
// NOTE: "extra usage" is pay-as-you-go spend on TOP of whatever the plan includes.
// It is not a total token allowance. On this Enterprise seat the API reports no
// rate-limit windows at all, so included capacity is not visible from this machine.
//
// Data source: ~/Library/Application Support/Claude/plan-usage-history.json, the
// sample log Claude Desktop appends to every ~15 minutes. Read-only, no credentials,
// no network. Each sample looks like:
//   {"t": <epoch ms>, "org": "<uuid>", "u": {"xu": 9.52}}
// where "u" carries percent-used figures and is often empty (nothing new that poll).
// The pace estimate needs the *history* of samples, not just the latest one, so we
// keep the whole array in memory rather than just scanning for the last non-empty one.

let usageLogPath = NSString(string: "~/Library/Application Support/Claude/plan-usage-history.json")
    .expandingTildeInPath
let configPath = NSString(string: "~/.config/claude-meter/config.json").expandingTildeInPath

/// Claude Desktop polls roughly every 15 minutes; past this we stop trusting the number.
let stalenessThreshold: TimeInterval = 45 * 60

// MARK: - Model

/// One sample from the log that actually reported a figure.
struct Sample {
    var date: Date
    var meters: [String: Double]
}

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

func loadSamples() -> [Sample] {
    guard let data = FileManager.default.contents(atPath: usageLogPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawSamples = root["samples"] as? [[String: Any]]
    else { return [] }

    var samples: [Sample] = []
    for sample in rawSamples {
        guard let raw = sample["u"] as? [String: Any], !raw.isEmpty,
              let millis = sample["t"] as? Double
        else { continue }

        var meters: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? Double { meters[key] = number }
        }
        guard !meters.isEmpty else { continue }

        samples.append(Sample(date: Date(timeIntervalSince1970: millis / 1000), meters: meters))
    }
    return samples
}

func loadReading(from samples: [Sample]) -> Reading? {
    guard let last = samples.last else { return nil }
    return Reading(meters: last.meters, sampledAt: last.date)
}

// MARK: - Config

struct Config {
    /// The dollar ceiling isn't recorded anywhere on disk, so it lives in a config file.
    var monthlyLimitUSD: Double = 50.0
    /// Pace projections assume a calendar-month reset unless this overrides it with a
    /// rolling window (in days) from the start of the current cycle.
    var cycleLengthDays: Int?
}

func loadConfig() -> Config {
    var config = Config()
    guard let data = FileManager.default.contents(atPath: configPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return config }
    if let limit = root["monthlyLimitUSD"] as? Double { config.monthlyLimitUSD = limit }
    if let days = root["cycleLengthDays"] as? Int { config.cycleLengthDays = days }
    return config
}

// MARK: - Pace estimate

struct PaceEstimate {
    /// Percentage-points of the cap consumed per day, at the rate used for the projection —
    /// whichever of `recentRatePercent` / `averageRatePercent` is higher, so a quiet spell
    /// right now doesn't hide a heavy morning that's still going to land somewhere.
    var dailyRatePercent: Double
    /// Which of the two rates drove `dailyRatePercent`, for the menu label.
    var rateBasis: String
    /// Rate over the last ~3 hours, when there's enough spread in that window to trust it.
    var recentRatePercent: Double?
    /// Rate averaged over the whole current cycle so far.
    var averageRatePercent: Double
    /// Where percent-used would land by the end of the cycle if this rate holds.
    var projectedEndPercent: Double
    var daysRemainingInCycle: Int
    /// When 100% would be hit at this rate, if it's on pace to happen at all.
    var exhaustionDate: Date?
}

enum PaceVerdict: Equatable {
    case alreadyOver
    case trendingOver
    case cuttingItClose
    case trendingUnder

    var label: String {
        switch self {
        case .alreadyOver: return "Already over the cap"
        case .trendingOver: return "Trending OVER the cap"
        case .cuttingItClose: return "Cutting it close"
        case .trendingUnder: return "Trending under the cap"
        }
    }

    var mark: String {
        switch self {
        case .alreadyOver, .trendingOver: return "🔺"
        case .cuttingItClose: return "⚠️"
        case .trendingUnder: return "✅"
        }
    }
}

func verdict(currentPercent: Double, projectedEndPercent: Double) -> PaceVerdict {
    if currentPercent >= 100 { return .alreadyOver }
    if projectedEndPercent >= 100 { return .trendingOver }
    if projectedEndPercent >= 85 { return .cuttingItClose }
    return .trendingUnder
}

/// A dollar cap resets to zero, which would otherwise look like usage suddenly
/// dropping. Find the most recent such drop and only look at history after it, so
/// a rolled-over cycle doesn't pollute the current one's pace.
func trimToCurrentCycle(_ points: [Sample], key: String) -> [(date: Date, percent: Double)] {
    let series = points.compactMap { sample -> (date: Date, percent: Double)? in
        guard let percent = sample.meters[key] else { return nil }
        return (sample.date, percent)
    }
    guard series.count > 1 else { return series }

    var startIndex = 0
    for i in 1..<series.count where series[i].percent < series[i - 1].percent - 0.05 {
        startIndex = i
    }
    return Array(series[startIndex...])
}

/// Needs at least ~20 minutes of same-cycle history to say anything meaningful;
/// below that a single noisy sample could produce a wild extrapolated rate.
func computePace(currentPercent: Double, samples: [Sample], meterKey: String, config: Config) -> PaceEstimate? {
    let cycle = trimToCurrentCycle(samples, key: meterKey)
    guard let cycleStart = cycle.first, let latest = cycle.last,
          latest.date.timeIntervalSince(cycleStart.date) >= 20 * 60
    else { return nil }

    // Average over the whole cycle so far, and — separately — the last 3 hours, so a
    // quiet stretch right now can't hide a heavy burst earlier in the cycle. Use
    // whichever is higher: a pace estimate that's meant to catch "trending over" should
    // err toward the more alarming of the two, not the more current one.
    let overallSeconds = latest.date.timeIntervalSince(cycleStart.date)
    let averageRate = overallSeconds > 0
        ? max(0, (latest.percent - cycleStart.percent) / overallSeconds * 86400) : 0

    let recentCutoff = latest.date.addingTimeInterval(-3 * 60 * 60)
    let recentPoints = cycle.filter { $0.date >= recentCutoff }
    var recentRate: Double?
    if recentPoints.count >= 2,
       recentPoints.last!.date.timeIntervalSince(recentPoints.first!.date) >= 20 * 60 {
        let seconds = recentPoints.last!.date.timeIntervalSince(recentPoints.first!.date)
        recentRate = max(0, (recentPoints.last!.percent - recentPoints.first!.percent) / seconds * 86400)
    }

    let dailyRate: Double
    let rateBasis: String
    if let recentRate, recentRate > averageRate {
        dailyRate = recentRate
        rateBasis = "last 3h"
    } else {
        dailyRate = averageRate
        rateBasis = "cycle average"
    }

    let now = Date()
    let calendar = Calendar.current
    let cycleEnd: Date
    if let cycleLengthDays = config.cycleLengthDays {
        cycleEnd = cycleStart.date.addingTimeInterval(Double(cycleLengthDays) * 86400)
    } else {
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        cycleEnd = calendar.date(byAdding: .month, value: 1, to: startOfThisMonth)!
    }
    let daysRemaining = max(0, calendar.dateComponents([.day], from: now, to: cycleEnd).day ?? 0)

    let projected = currentPercent + dailyRate * Double(daysRemaining)

    var exhaustionDate: Date?
    if dailyRate > 0.0001, currentPercent < 100 {
        let daysToExhaust = (100 - currentPercent) / dailyRate
        exhaustionDate = now.addingTimeInterval(daysToExhaust * 86400)
    }

    return PaceEstimate(dailyRatePercent: dailyRate, rateBasis: rateBasis,
                         recentRatePercent: recentRate, averageRatePercent: averageRate,
                         projectedEndPercent: projected, daysRemainingInCycle: daysRemaining,
                         exhaustionDate: exhaustionDate)
}

// MARK: - Menu bar icon

/// The real Claude app icon, read from the locally installed Claude Desktop at
/// runtime — never bundled or redistributed by this app, just looked up the same
/// way Finder or the Dock would show any other app's icon.
private let claudeAppPaths = ["/Applications/Claude.app"]

func loadClaudeIcon() -> NSImage? {
    for path in claudeAppPaths where FileManager.default.fileExists(atPath: path) {
        return NSWorkspace.shared.icon(forFile: path)
    }
    return nil
}

/// Extracts just the sunburst mark from the app icon — dropping both the solid
/// background fill and the thin rim around its rounded-square edge — as a
/// template image: a shape-only mask with no fixed color of its own, so AppKit
/// auto-tints it to match the surrounding menu bar text exactly, in any theme
/// (the same mechanism most menu bar icons use, e.g. the lock/extension icons
/// next to this one).
///
/// Two passes over the pixels: brightness picks out the white mark (and,
/// unfortunately, the rim, which is bright too); a margin around the edges then
/// discards the rim specifically, since it hugs the icon's outer edge and the
/// rays don't reach that far. The result is cropped tightly to the mark's own
/// bounding box so it fills the small icon frame instead of floating in
/// transparent padding.
func silhouette(of icon: NSImage, pixelSize: Int = 512, threshold: CGFloat = 0.6,
                 edgeInset: CGFloat = 0.18) -> NSImage? {
    var rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let width = cgImage.width, height = cgImage.height
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }

    let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let insetPx = Int(CGFloat(width) * edgeInset)
    var minX = width, maxX = 0, minY = height, maxY = 0

    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let alpha = CGFloat(buffer[i + 3]) / 255
            let nearEdge = x < insetPx || x >= width - insetPx || y < insetPx || y >= height - insetPx
            guard alpha > 0.95, !nearEdge else { buffer[i + 3] = 0; continue }
            let luminance = 0.299 * CGFloat(buffer[i]) / 255
                + 0.587 * CGFloat(buffer[i + 1]) / 255
                + 0.114 * CGFloat(buffer[i + 2]) / 255
            let keep = luminance > threshold
            buffer[i + 3] = keep ? 255 : 0
            buffer[i] = 255; buffer[i + 1] = 255; buffer[i + 2] = 255 // template images ignore RGB anyway
            if keep {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard let fullCG = context.makeImage(), maxX > minX, maxY > minY else { return nil }

    let pad = Int(CGFloat(maxX - minX) * 0.06)
    let cropRect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                           width: min(width, maxX - minX + pad * 2),
                           height: min(height, maxY - minY + pad * 2))
    guard let croppedCG = fullCG.cropping(to: cropRect) else { return nil }

    let result = NSImage(cgImage: croppedCG, size: NSSize(width: 18, height: 18))
    result.isTemplate = true
    return result
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
    private let iconSilhouette = loadClaudeIcon().flatMap { silhouette(of: $0) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        statusItem.button?.imagePosition = .imageLeading

        refresh()
        startWatching()

        // Backstop for the file watch, and it keeps the "updated N ago" text honest.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Display

    @objc func refresh() {
        let samples = loadSamples()
        let reading = loadReading(from: samples)
        renderTitle(reading)
        rebuildMenu(reading, samples: samples)
    }

    private func renderTitle(_ reading: Reading?) {
        guard let button = statusItem.button else { return }

        // The icon is a template image, so it always matches the menu bar's own
        // text color automatically — no manual color logic needed for it, in any
        // theme. Only the percentage text carries the warning color.
        button.image = iconSilhouette

        guard let reading, let headline = reading.headline else {
            button.attributedTitle = styled(" —", color: .secondaryLabelColor)
            button.alphaValue = 0.5
            button.toolTip = "No usage figures recorded yet. Claude Desktop writes these every ~15 minutes."
            return
        }

        let used = headline.percentUsed
        let color: NSColor = used >= 90 ? .systemRed : used >= 75 ? .systemOrange : .labelColor
        button.attributedTitle = styled(" \(Int(used.rounded()))%", color: color)
        button.alphaValue = reading.isStale ? 0.5 : 1.0
        button.toolTip = "\(label(forMeterKey: headline.key)): \(Int(used.rounded()))% of extra-usage cap used"
    }

    private func styled(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func rebuildMenu(_ reading: Reading?, samples: [Sample]) {
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

        let config = loadConfig()
        let used = headline.percentUsed
        info("\(Int(used.rounded()))% of extra-usage cap used")

        let spent = config.monthlyLimitUSD * used / 100
        info(String(format: "$%.2f of $%.2f used", spent, config.monthlyLimitUSD))

        // Anything beyond the headline meter, shown rather than hidden.
        for (key, otherUsed) in reading.meters.sorted(by: { $0.key < $1.key }) where key != headline.key {
            info(String(format: "%@: %.0f%% used", label(forMeterKey: key), otherUsed))
        }

        menu.addItem(.separator())
        addPaceSection(to: menu, info: info, currentPercent: used, samples: samples,
                       meterKey: headline.key, config: config)

        menu.addItem(.separator())

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        info("Updated \(formatter.localizedString(for: reading.sampledAt, relativeTo: Date()))")
        if reading.isStale {
            info("⚠︎ Stale — is Claude Desktop running?")
        }

        addControls(to: menu)
    }

    /// The "am I trending over or under" readout, kept to two lines: a verdict with
    /// the number that matters most for it, then the raw rate for anyone who wants it.
    private func addPaceSection(to menu: NSMenu, info: (String) -> Void, currentPercent: Double,
                                 samples: [Sample], meterKey: String, config: Config) {
        guard let pace = computePace(currentPercent: currentPercent, samples: samples,
                                      meterKey: meterKey, config: config) else {
            info("Pace: not enough data yet")
            return
        }

        let result = verdict(currentPercent: currentPercent, projectedEndPercent: pace.projectedEndPercent)
        switch result {
        case .alreadyOver:
            info("\(result.mark) Already over — resets in \(pace.daysRemainingInCycle)d")
        case .trendingOver:
            if let exhaustionDate = pace.exhaustionDate {
                let days = max(0, Int(ceil(exhaustionDate.timeIntervalSinceNow / 86400)))
                info("\(result.mark) On pace to hit the cap in ~\(days)d")
            } else {
                info("\(result.mark) \(result.label) (~\(Int(pace.projectedEndPercent))% by reset)")
            }
        case .cuttingItClose, .trendingUnder:
            info("\(result.mark) \(result.label) (~\(Int(pace.projectedEndPercent))% by reset)")
        }
        info(String(format: "%.0f%%/day · %d days left in cycle", pace.dailyRatePercent, pace.daysRemainingInCycle))
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
    let samples = loadSamples()
    guard let reading = loadReading(from: samples), let headline = reading.headline else {
        print("no usage data in \(usageLogPath)")
        exit(1)
    }
    let config = loadConfig()
    let used = headline.percentUsed
    print(String(format: "used:       %.0f%%", used))
    print(String(format: "spent:      $%.2f of $%.2f", config.monthlyLimitUSD * used / 100, config.monthlyLimitUSD))
    print("headline:   \(label(forMeterKey: headline.key)) (\(headline.key))")
    print("meters:     \(reading.meters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    print("sampled:    \(reading.sampledAt)\(reading.isStale ? "  [stale]" : "")")

    if let pace = computePace(currentPercent: used, samples: samples, meterKey: headline.key, config: config) {
        let result = verdict(currentPercent: used, projectedEndPercent: pace.projectedEndPercent)
        print("pace:       \(String(format: "%.2f", pace.dailyRatePercent))%/day (\(pace.rateBasis))")
        print("  average:  \(String(format: "%.2f", pace.averageRatePercent))%/day since cycle start")
        if let recentRate = pace.recentRatePercent {
            print("  last 3h:  \(String(format: "%.2f", recentRate))%/day")
        }
        print(String(format: "projected:  %.0f%% by cycle end (%d days remaining)",
                      pace.projectedEndPercent, pace.daysRemainingInCycle))
        print("verdict:    \(result.mark) \(result.label)")
        if let exhaustionDate = pace.exhaustionDate {
            print("exhausts:   \(exhaustionDate)")
        }
    } else {
        print("pace:       not enough data yet")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

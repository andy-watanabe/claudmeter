import Cocoa

// ClaudeMeter — a menu bar readout of how much of your Claude usage limits have been
// used, plus a pace estimate (are you trending over or under before the reset).
//
// NOTE: "extra usage" is pay-as-you-go spend on TOP of whatever the plan includes.
// It is not a total token allowance. Which meters show up depends on the org: one
// Enterprise org reported only "xu" (extra usage, monthly cap); another reports only
// "fh"/"sd" (rolling rate-limit windows, no extra usage at all).
//
// Data source: ~/Library/Application Support/Claude/plan-usage-history.json, the
// sample log Claude Desktop appends to every ~15 minutes. Read-only, no credentials,
// no network. Each sample looks like:
//   {"t": <epoch ms>, "org": "<uuid>", "u": {"xu": 9.52}}
// where "u" carries percent-used figures and is often empty (nothing new that poll).
// The pace estimate needs the *history* of samples, not just the latest one, so we
// keep the whole array in memory rather than just scanning for the last non-empty one.
//
// The log is shared across orgs: switching orgs doesn't start a new file, it just
// starts tagging samples with a different "org". Budgets are per org, so only the
// current org's samples are ever used -- mixing them produced a headline from one
// org's meter and a pace built from both orgs' history.

/// Overridable so the health/pace logic can be exercised against fixture logs
/// (real ones take hours to produce the states worth testing).
let usageLogPath = ProcessInfo.processInfo.environment["CLAUDEMETER_LOG_PATH"]
    ?? NSString(string: "~/Library/Application Support/Claude/plan-usage-history.json")
        .expandingTildeInPath
let configPath = NSString(string: "~/.config/claude-meter/config.json").expandingTildeInPath

// Claude Desktop writes a sample to the log every ~15 minutes, but most of them
// carry no figure at all -- an empty `u`. Actual figures land every 1-2.5 hours.
// So "the log stopped being written" and "the figure hasn't changed" are two
// different conditions with two different causes, and conflating them (as an
// earlier version did, warning after 45 minutes without a figure) produces a
// warning that fires constantly during completely normal operation.

/// No sample of any kind in this long means Claude Desktop isn't writing -- it
/// polls every ~15 min, so three missed polls is a real signal.
let pollGapThreshold: TimeInterval = 45 * 60

/// Figures update far less often than polls. Only flag one as lagging well past
/// the widest normal gap actually observed in the log.
let figureGapThreshold: TimeInterval = 4 * 60 * 60

// MARK: - Model

/// One sample from the log that actually reported a figure.
struct Sample {
    var date: Date
    var meters: [String: Double]
}

/// What's in the log for the current org, split by the distinction above.
struct UsageLog {
    /// The org of the most recent sample of any kind -- whichever org Claude Desktop
    /// is signed into now. Nil only for an empty log, or one written before samples
    /// carried an org.
    var org: String?
    /// Only the current org's samples carrying a figure.
    var samples: [Sample]
    /// The current org's most recent sample of any kind, empty ones included --
    /// i.e. the last time Claude Desktop demonstrably did anything.
    var lastPollAt: Date?
}

/// Why the number on screen might not be current. These need different wording:
/// telling someone to check whether Claude Desktop is running, when it's running
/// fine and just hasn't had a new figure to report, sends them after a non-problem.
enum DataHealth {
    case fresh
    case figureLagging
    case notPolling

    /// Never, now: Claude Desktop pauses its checks by design, so a quiet log is
    /// normal and a dimmed menu bar would be permanent. Staleness that matters --
    /// a window that has rolled over -- is shown on the figure itself instead.
    var shouldDim: Bool { false }
}

func dataHealth(figureAt: Date, lastPollAt: Date?, now: Date = Date()) -> DataHealth {
    if let lastPollAt, now.timeIntervalSince(lastPollAt) > pollGapThreshold { return .notPolling }
    if now.timeIntervalSince(figureAt) > figureGapThreshold { return .figureLagging }
    return .fresh
}

struct Reading {
    /// Percent *used* per meter, keyed as the log keys them ("xu" = extra usage).
    var meters: [String: Double]
    var sampledAt: Date

    /// The headline meter. The one picked in the menu, if this org reports it.
    /// Otherwise extra usage when the org reports it; otherwise the 7-day window,
    /// since that's the one that locks you out for days (the 5-hour one fills and
    /// empties within an afternoon, which makes a jumpy headline); failing both,
    /// whichever meter is furthest along.
    var headline: (key: String, percentUsed: Double)? {
        if let key = preferredMeterKey, let picked = meters[key] { return (key, picked) }
        if let xu = meters["xu"] { return ("xu", xu) }
        if let sd = meters["sd"] { return ("sd", sd) }
        guard let worst = meters.max(by: { $0.value < $1.value }) else { return nil }
        return (worst.key, worst.value)
    }
}

/// The meter picked under "Show in Menu Bar". Kept even when the current org
/// doesn't report it, so switching orgs and back doesn't lose the choice.
let preferredMeterDefaultsKey = "menuBarMeter"
var preferredMeterKey: String? {
    get { UserDefaults.standard.string(forKey: preferredMeterDefaultsKey) }
    set { UserDefaults.standard.set(newValue, forKey: preferredMeterDefaultsKey) }
}

/// How a meter resets, which decides what its pace is measured against.
enum MeterCycle {
    /// The billing cycle: calendar month, or `Config.cycleLengthDays`.
    case billing
    /// A window of fixed length that starts when usage starts and then resets.
    case window(TimeInterval)
    /// A key we haven't seen before. No pace, since we'd be guessing at the reset.
    case unknown
}

/// The keys are Claude Desktop's own short names, from the code that writes the
/// log: five_hour → "fh", seven_day → "sd", seven_day_opus → "so", and so on, plus
/// "xu" for extra usage. The per-model and per-surface ones haven't been seen in a
/// real log yet. "om"/"op" are internal codenames, so they're left as-is.
func meterInfo(forKey key: String) -> (label: String, cycle: MeterCycle) {
    switch key {
    case "xu": return ("Extra usage", .billing)
    case "fh": return ("5-hour window", .window(5 * 60 * 60))
    case "sd": return ("7-day window", .window(7 * 86400))
    case "so": return ("7-day Opus window", .window(7 * 86400))
    case "sn": return ("7-day Sonnet window", .window(7 * 86400))
    case "cw": return ("7-day Cowork window", .window(7 * 86400))
    case "oa": return ("7-day connected-apps window", .window(7 * 86400))
    default: return (key, .unknown)
    }
}

func label(forMeterKey key: String) -> String { meterInfo(forKey: key).label }

/// The headline sentence for a meter, e.g. "6% of extra-usage cap used".
func usedLine(key: String, percent: Double) -> String {
    let rounded = Int(percent.rounded())
    return key == "xu" ? "\(rounded)% of extra-usage cap used" : "\(label(forMeterKey: key)): \(rounded)% used"
}

/// A few characters for the menu bar, so the number says which limit it is:
/// "mo" for a monthly cap, "5h"/"7d" for the windows.
func cadenceTag(forKey key: String, config: Config) -> String {
    switch meterInfo(forKey: key).cycle {
    case .billing: return config.cycleLengthDays.map { "\($0)d" } ?? "mo"
    case .window(let length): return length >= 86400 ? "\(Int(length / 86400))d" : "\(Int(length / 3600))h"
    case .unknown: return key
    }
}

/// One line saying what kind of budget this org has, since orgs differ: a monthly
/// cap, rolling windows, or both. Reports what's in the log, not what's promised.
func limitsSummary(meterKeys: [String], config: Config) -> String {
    var billing: [String] = [], windows: [String] = [], unknown: [String] = []
    for key in meterKeys.sorted(by: { cadenceOrder($0) < cadenceOrder($1) }) {
        switch meterInfo(forKey: key).cycle {
        case .billing: billing.append(config.cycleLengthDays.map { "\($0)-day cap" } ?? "monthly cap")
        case .window: windows.append(label(forMeterKey: key).replacingOccurrences(of: " window", with: ""))
        case .unknown: unknown.append(key)
        }
    }
    var parts: [String] = billing
    if !windows.isEmpty { parts.append(windows.joined(separator: " + ") + (windows.count > 1 ? " windows" : " window")) }
    parts += unknown
    let summary = "Limits: " + parts.joined(separator: ", ")
    return billing.isEmpty ? summary + " (no monthly budget)" : summary
}

/// Shortest reset first, so "5-hour + 7-day" reads in the natural order.
func cadenceOrder(_ key: String) -> TimeInterval {
    switch meterInfo(forKey: key).cycle {
    case .window(let length): return length
    case .billing: return 30 * 86400
    case .unknown: return .infinity
    }
}

/// "3h", "40m", "2d" -- coarse on purpose, since reset times are estimates.
func shortDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, seconds)
    if s >= 2 * 86400 { return "\(Int((s / 86400).rounded()))d" }
    if s >= 90 * 60 { return "\(Int((s / 3600).rounded()))h" }
    return "\(max(1, Int((s / 60).rounded())))m"
}

// MARK: - Reading the log

func loadLog() -> UsageLog {
    guard let data = FileManager.default.contents(atPath: usageLogPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawSamples = root["samples"] as? [[String: Any]]
    else { return UsageLog(org: nil, samples: [], lastPollAt: nil) }

    // Parse everything first: the current org is only known once the latest poll
    // of any kind has been seen.
    var all: [(org: String?, sample: Sample?, date: Date)] = []
    var latest: (org: String?, date: Date)?

    for sample in rawSamples {
        guard let millis = sample["t"] as? Double else { continue }
        let date = Date(timeIntervalSince1970: millis / 1000)
        let org = sample["org"] as? String

        // Every sample counts as a poll, figure or not -- that's the whole point
        // of tracking it separately.
        if latest == nil || date > latest!.date { latest = (org, date) }

        var meters: [String: Double] = [:]
        for (key, value) in sample["u"] as? [String: Any] ?? [:] {
            if let number = value as? Double { meters[key] = number }
        }
        all.append((org, meters.isEmpty ? nil : Sample(date: date, meters: meters), date))
    }

    let org = latest?.org
    let mine = all.filter { $0.org == org }
    return UsageLog(org: org,
                    samples: mine.compactMap(\.sample).sorted { $0.date < $1.date },
                    lastPollAt: mine.map(\.date).max())
}

/// The latest value of each meter. A sample needn't carry every meter, so each
/// key takes its own most recent figure rather than all coming from the last sample.
func loadReading(from samples: [Sample]) -> Reading? {
    guard let last = samples.last else { return nil }
    var meters: [String: Double] = [:]
    for sample in samples { meters.merge(sample.meters) { _, new in new } }
    return Reading(meters: meters, sampledAt: last.date)
}

// MARK: - Config

struct Config {
    /// Pace projections assume a calendar-month reset unless this overrides it with a
    /// rolling window (in days) from the start of the current cycle.
    ///
    /// There's deliberately no dollar-cap setting here. That figure isn't recorded
    /// anywhere in Claude Desktop's local data (checked, including its IndexedDB and
    /// Local Storage caches) — the only place it exists is behind Anthropic's own
    /// authenticated API, the same one that powers Claude Desktop's native usage
    /// popover. Reading it would mean either extracting Claude Desktop's session
    /// credentials to call an undocumented endpoint, or scraping its UI via the
    /// Accessibility API — both a bigger, shakier step than this app should take
    /// for one dollar figure. The percentage below needs none of that: it's read
    /// directly from Claude Desktop's own log and is always correct.
    var cycleLengthDays: Int?
}

func loadConfig() -> Config {
    var config = Config()
    guard let data = FileManager.default.contents(atPath: configPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return config }
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
    /// When the meter resets. For windows this is estimated from the first figure
    /// after the last reset, so it can run late by up to one gap between figures.
    var cycleEnd: Date
    var secondsRemaining: TimeInterval
    /// When 100% would be hit at this rate, if it's on pace to happen at all.
    var exhaustionDate: Date?
}

enum PaceVerdict: Equatable {
    case alreadyOver
    case trendingOver
    case cuttingItClose
    case trendingUnder

    /// `noun` is "cap" for extra usage, "limit" for rate-limit windows.
    func label(_ noun: String) -> String {
        switch self {
        case .alreadyOver: return "Already over the \(noun)"
        case .trendingOver: return "Trending OVER the \(noun)"
        case .cuttingItClose: return "Cutting it close"
        case .trendingUnder: return "Trending under the \(noun)"
        }
    }

    var mark: String {
        switch self {
        case .alreadyOver, .trendingOver: return "🔺"
        case .cuttingItClose: return "⚠️"
        case .trendingUnder: return "✅"
        }
    }

    var color: NSColor {
        switch self {
        case .alreadyOver, .trendingOver: return .systemRed
        case .cuttingItClose: return .systemOrange
        case .trendingUnder: return .labelColor
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

/// Whether a meter has probably reset since its last figure, so that figure no
/// longer describes now. Claude Desktop only fetches new figures at startup now
/// (it pauses background checks unless its own menu bar panel was opened in the
/// last day), so a figure can easily be a day old. Showing a window's old 27% as
/// current, after the window has rolled over, is the one thing this app must not do.
func likelyResetSinceLastFigure(key: String, samples: [Sample], config: Config, now: Date = Date()) -> Bool {
    let cycle = trimToCurrentCycle(samples, key: key)
    guard let start = cycle.first, let last = cycle.last else { return false }
    switch meterInfo(forKey: key).cycle {
    case .window(let length):
        return start.date.addingTimeInterval(length) <= now
    case .billing:
        if let days = config.cycleLengthDays {
            return start.date.addingTimeInterval(Double(days) * 86400) <= now
        }
        return !Calendar.current.isDate(last.date, equalTo: now, toGranularity: .month)
    case .unknown:
        return false
    }
}

/// Needs at least ~20 minutes of same-cycle history to say anything meaningful;
/// below that a single noisy sample could produce a wild extrapolated rate.
/// Returns nil for meters whose reset we don't know, and for a window whose
/// estimated reset has already passed (the last figure is stale, not a trend).
func computePace(currentPercent: Double, samples: [Sample], meterKey: String, config: Config,
                 now: Date = Date()) -> PaceEstimate? {
    let meterCycle = meterInfo(forKey: meterKey).cycle
    if case .unknown = meterCycle { return nil }

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

    let cycleEnd: Date
    switch meterCycle {
    case .window(let length):
        cycleEnd = cycleStart.date.addingTimeInterval(length)
        if cycleEnd <= now { return nil }
    case .billing, .unknown:
        if let cycleLengthDays = config.cycleLengthDays {
            cycleEnd = cycleStart.date.addingTimeInterval(Double(cycleLengthDays) * 86400)
        } else {
            let calendar = Calendar.current
            let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            cycleEnd = calendar.date(byAdding: .month, value: 1, to: startOfThisMonth)!
        }
    }
    let secondsRemaining = max(0, cycleEnd.timeIntervalSince(now))

    let projected = currentPercent + dailyRate * secondsRemaining / 86400

    var exhaustionDate: Date?
    if dailyRate > 0.0001, currentPercent < 100 {
        let daysToExhaust = (100 - currentPercent) / dailyRate
        let date = now.addingTimeInterval(daysToExhaust * 86400)
        // Past the reset it never happens -- the meter goes back to zero first.
        if date <= cycleEnd { exhaustionDate = date }
    }

    return PaceEstimate(dailyRatePercent: dailyRate, rateBasis: rateBasis,
                         recentRatePercent: recentRate, averageRatePercent: averageRate,
                         projectedEndPercent: projected, cycleEnd: cycleEnd,
                         secondsRemaining: secondsRemaining, exhaustionDate: exhaustionDate)
}

// MARK: - Mac load
//
// Sprout's fill shows how hard the Mac is working, not Claude usage: since
// Claude Desktop stopped checking usage in the background, usage figures can be
// hours old, while the Mac's load is always live. The menu explains the fill,
// and traces busy processes back to the Claude session that started them --
// the one thing Activity Monitor can't tell you.

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    static var current: MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    /// On the same 0-100 scale as CPU. Swapping hard slows everything even with
    /// idle cores, so "warning" counts as strained on its own.
    var score: Double { switch self { case .normal: 0; case .warning: 80; case .critical: 95 } }
    var label: String { switch self { case .normal: "normal"; case .warning: "high"; case .critical: "critical" } }
}

struct MacLoad {
    /// Share of all cores busy, smoothed over about half a minute.
    var cpuPercent: Double
    /// Processes running or waiting to run, averaged over the last minute.
    var loadAverage: Double
    var cores: Int
    var memoryPressure: MemoryPressure
    var swapUsedGB: Double
    var swapTotalGB: Double
    var thermal: ProcessInfo.ThermalState

    private var thermalScore: Double {
        switch thermal {
        case .nominal: 0
        case .fair: 50
        case .serious: 85
        case .critical: 100
        @unknown default: 0
        }
    }

    /// 0-100: whichever of CPU, memory, or heat is worst. One bad one is enough
    /// to make the Mac feel slow.
    var score: Double { max(cpuPercent, memoryPressure.score, thermalScore) }

    var level: String {
        switch score {
        case ..<40: "Calm"
        case ..<75: "Busy"
        case ..<90: "Strained"
        default: "Overloaded"
        }
    }

    var color: NSColor { score >= 90 ? .systemRed : score >= 75 ? .systemOrange : .labelColor }

    /// Sprout droops at "Strained", and sweats at "Overloaded".
    var tired: Bool { score >= 75 }
    var sweating: Bool { score >= 90 }
}

/// Samples CPU ticks every few seconds. Busy share comes from the change in
/// ticks between samples, smoothed so one spike doesn't flap the icon.
final class MacLoadSampler {
    private var lastTicks: (busy: Double, total: Double)?
    private var smoothedCPU: Double?

    private static func ticks() -> (busy: Double, total: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = Double(t.0), system = Double(t.1), idle = Double(t.2), nice = Double(t.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// `interval` is the seconds since the last call, for the smoothing.
    func sample(interval: TimeInterval = 5) -> MacLoad {
        if let now = Self.ticks() {
            if let last = lastTicks, now.total > last.total {
                let busy = 100 * (now.busy - last.busy) / (now.total - last.total)
                let alpha = 1 - exp(-interval / 30)
                smoothedCPU = smoothedCPU.map { $0 + alpha * (busy - $0) } ?? busy
            }
            lastTicks = now
        }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        return MacLoad(cpuPercent: smoothedCPU ?? 0,
                       loadAverage: loads[0],
                       cores: ProcessInfo.processInfo.activeProcessorCount,
                       memoryPressure: .current,
                       swapUsedGB: Double(swap.xsu_used) / 1_073_741_824,
                       swapTotalGB: Double(swap.xsu_total) / 1_073_741_824,
                       thermal: ProcessInfo.processInfo.thermalState)
    }
}

/// One process from `ps`.
struct ProcessEntry {
    var pid: Int32
    var ppid: Int32
    var cpu: Double
    var memoryKB: Double
    var path: String
}

/// What's using the Mac, grouped the way a person thinks about it: by app, or by
/// the Claude session that started the work.
struct LoadGroup {
    var label: String
    var cpu: Double
    var memoryKB: Double
}

struct ProcessSnapshot {
    var groups: [LoadGroup]
    var claudeSessions: Int
    var claudeSessionMemoryKB: Double
}

func runCommand(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func listProcesses() -> [ProcessEntry] {
    // comm last: it's the full executable path, which can contain spaces.
    runCommand("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,rss=,comm="])
        .split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]), let rss = Double(parts[3]) else { return nil }
            return ProcessEntry(pid: pid, ppid: ppid, cpu: cpu, memoryKB: rss, path: String(parts[4]))
        }
}

/// A Claude Code session: the Code tab in Claude Desktop runs one under
/// Application Support, the terminal one under ~/.local/share/claude.
func isClaudeCodeSession(_ path: String) -> Bool {
    (path.contains("/claude-code/") && path.hasSuffix("/claude"))
        || path.contains("/.local/share/claude/versions/")
}

/// The folder a process is working in, e.g. the project a Claude session is in.
func workingDirectory(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) {
        String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
}

/// "npm exec vitest run", "swift-frontend -frontend…": paths cut to the program
/// name, and the whole thing kept short enough for a menu row.
func shortCommand(_ command: String) -> String {
    let words = command.split(separator: " ").prefix(4).map { word in
        word.hasPrefix("/") ? (String(word) as NSString).lastPathComponent : String(word)
    }
    let text = words.joined(separator: " ")
    return text.count > 32 ? String(text.prefix(31)) + "…" : text
}

func commandLine(of pid: Int32) -> String {
    runCommand("/bin/ps", ["-o", "args=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "Google Chrome" for anything inside Google Chrome.app, helpers included;
/// the file name for anything else.
func appName(forPath path: String) -> String {
    if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
        return String(app.dropLast(4))
    }
    return (path as NSString).lastPathComponent
}

func takeProcessSnapshot() -> ProcessSnapshot {
    let processes = listProcesses()
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

    /// The process's ancestors, nearest first, stopping at launchd.
    func ancestors(of pid: Int32) -> [ProcessEntry] {
        var chain: [ProcessEntry] = []
        var current = byPID[pid]?.ppid
        while let id = current, id > 1, let parent = byPID[id], chain.count < 40 {
            chain.append(parent)
            current = parent.ppid
        }
        return chain
    }

    var groups: [String: LoadGroup] = [:]
    var commandBySession: [Int32: (pid: Int32, cpu: Double)] = [:]

    for process in processes where process.pid != getpid() {
        let chain = ancestors(of: process.pid)
        var key: String
        if isClaudeCodeSession(process.path) {
            key = "claude:\(process.pid)"
        } else if let sessionIndex = chain.firstIndex(where: { isClaudeCodeSession($0.path) }) {
            let session = chain[sessionIndex]
            key = "claude:\(session.pid)"
            // The command the session ran: its child, or the shell's child when
            // it ran through a shell, which Claude Code always does.
            let path = [process] + chain
            let below = Array(path[..<(sessionIndex + 1)].reversed())  // child of session first
            var command = below.first
            if let first = command, ["zsh", "bash", "sh"].contains((first.path as NSString).lastPathComponent),
               below.count > 1 {
                command = below[1]
            }
            if let command, process.cpu > (commandBySession[session.pid]?.cpu ?? 0) {
                commandBySession[session.pid] = (command.pid, process.cpu)
            }
        } else {
            key = "app:" + appName(forPath: process.path)
        }
        var group = groups[key] ?? LoadGroup(label: key, cpu: 0, memoryKB: 0)
        group.cpu += process.cpu
        group.memoryKB += process.memoryKB
        groups[key] = group
    }

    // Labels for Claude sessions: the project folder, and what it's running.
    // The command's own folder beats the session's: sessions often start in a
    // parent folder like ~/code and cd into the project to run things.
    for (key, var group) in groups where key.hasPrefix("claude:") {
        guard let pid = Int32(key.dropFirst("claude:".count)) else { continue }
        let command = group.cpu >= 10 ? commandBySession[pid] : nil
        let folder = (command.flatMap { workingDirectory(of: $0.pid) } ?? workingDirectory(of: pid))
            .map { ($0 as NSString).lastPathComponent } ?? "?"
        var label = "Claude · \(folder)"
        if let command {
            let text = shortCommand(commandLine(of: command.pid))
            if !text.isEmpty { label += ": \(text)" }
        }
        group.label = label
        groups[key] = group
    }
    for (key, var group) in groups where key.hasPrefix("app:") {
        group.label = String(key.dropFirst("app:".count))
        groups[key] = group
    }

    let sessions = processes.filter { isClaudeCodeSession($0.path) }
    return ProcessSnapshot(groups: groups.values.sorted { $0.cpu > $1.cpu },
                           claudeSessions: sessions.count,
                           claudeSessionMemoryKB: sessions.reduce(0) { $0 + $1.memoryKB })
}

/// "1.4 cores", "40% of a core".
func coresText(_ cpuPercent: Double) -> String {
    cpuPercent >= 95 ? String(format: "%.1f cores", cpuPercent / 100) : "\(Int(cpuPercent.rounded()))% of a core"
}

func gigabytes(_ kilobytes: Double) -> String { String(format: "%.1f GB", kilobytes / 1_048_576) }

/// The lines the menu and `--dump` show for the Mac.
func macLoadLines(_ load: MacLoad, _ snapshot: ProcessSnapshot) -> [(text: String, emphasis: Bool)] {
    var lines: [(String, Bool)] = []
    lines.append(("Mac: \(load.level) — Sprout is \(Int(load.score.rounded()))% full", true))
    lines.append((String(format: "CPU %.0f%% busy · %.0f tasks for %d cores",
                         load.cpuPercent, load.loadAverage, load.cores), false))
    var memory = "Memory pressure \(load.memoryPressure.label)"
    if load.swapTotalGB > 0 {
        memory += String(format: " · swap %.1f of %.0f GB", load.swapUsedGB, load.swapTotalGB)
    }
    lines.append((memory, false))
    if load.thermal == .serious || load.thermal == .critical {
        lines.append(("Running hot — macOS is slowing the chip down", false))
    }
    let busiest = snapshot.groups.prefix(3).filter { $0.cpu >= 10 }
    if !busiest.isEmpty {
        lines.append(("Busiest:", false))
        for group in busiest { lines.append(("  \(group.label) · \(coresText(group.cpu))", false)) }
    }
    if let biggest = snapshot.groups.max(by: { $0.memoryKB < $1.memoryKB }) {
        lines.append(("Most memory: \(biggest.label) · \(gigabytes(biggest.memoryKB))", false))
    }
    if snapshot.claudeSessions > 0 {
        lines.append(("\(snapshot.claudeSessions) Claude Code sessions open · "
                      + gigabytes(snapshot.claudeSessionMemoryKB), false))
    }
    return lines
}

// MARK: - Menu bar icon

/// Sprout, ClaudeMeter's own pixel critter. Its body fills from the bottom as
/// the Mac gets busier (see `MacLoad.score`), and it droops and sweats when the
/// Mac is struggling. Drawn in code, no image files, and original on
/// purpose: this app never bundles Anthropic's logo or mascot.
///
/// `#` is always solid (antenna, feet). `b` is body: its outer edge is always
/// solid and the inside fills. `e` is an eye (open, the resting pose): solid
/// while the body around it is empty, a hole once it fills, so the face always
/// shows. Top row first.
///
/// The outline is what makes this work on any wallpaper. macOS squeezes menu
/// bar icons into a narrow contrast band on tinted menu bars, so a faint
/// "empty" body vanished there; solid-or-clear pixels don't.
private let sproutPixels = [
    ".........##........",
    "..........#........",
    "......bbbbbbbb.....",
    "....bbbbbbbbbbbb...",
    "...bbbbbbbbbbbbbb..",
    "..bbbbbbbbbbbbbbbb.",
    "..bbbbeebbbbeebbbb.",
    "..bbbbeebbbbeebbbb.",
    "..bbbbeebbbbeebbbb.",
    "..bbbbbbbbbbbbbbbb.",
    "..bbbbbbbbbbbbbbbb.",
    "..bbbbbbbbbbbbbbbb.",
    "..bbbbbbbbbbbbbbbb.",
    "...bbbbbbbbbbbbbb..",
    "....###......###...",
    "....###......###...",
]

/// "Animate Sprout" in the menu. On unless turned off.
let animateSproutDefaultsKey = "animateSprout"
var animateSprout: Bool {
    get { UserDefaults.standard.object(forKey: animateSproutDefaultsKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: animateSproutDefaultsKey) }
}

/// One frame of Sprout's idle moves. The default is the resting pose.
struct SproutPose {
    enum Eyes { case open, closed, lookingUp, lookingDown, lookingDownLeft, lookingDownRight }
    enum Arm: CaseIterable { case down, rising, scratchLow, scratchHigh }
    var eyes = Eyes.open
    var arm = Arm.down
}

struct SproutFrame {
    var pose: SproutPose
    var duration: TimeInterval
}

let sproutBlink = [
    SproutFrame(pose: SproutPose(eyes: .closed), duration: 0.14),
    SproutFrame(pose: SproutPose(), duration: 0),
]

/// How often Sprout does something bigger than a blink. Head scratches and
/// glances take turns.
let sproutMoveInterval: ClosedRange<TimeInterval> = 10...15

/// Looks down at the screen below the menu bar, scans left, then right, then
/// back up.
let sproutGlance = [
    SproutFrame(pose: SproutPose(eyes: .lookingDown), duration: 0.25),
    SproutFrame(pose: SproutPose(eyes: .lookingDownLeft), duration: 0.6),
    SproutFrame(pose: SproutPose(eyes: .lookingDown), duration: 0.15),
    SproutFrame(pose: SproutPose(eyes: .lookingDownRight), duration: 0.6),
    SproutFrame(pose: SproutPose(eyes: .lookingDown), duration: 0.25),
    SproutFrame(pose: SproutPose(), duration: 0),
]

/// Arm up, three scratches while looking up, arm down, then a blink.
let sproutScratch: [SproutFrame] = {
    let low = SproutFrame(pose: SproutPose(eyes: .lookingUp, arm: .scratchLow), duration: 0.15)
    let high = SproutFrame(pose: SproutPose(eyes: .lookingUp, arm: .scratchHigh), duration: 0.15)
    return [SproutFrame(pose: SproutPose(eyes: .lookingUp, arm: .rising), duration: 0.11)]
        + [low, high, low, high, low, high]
        + [SproutFrame(pose: SproutPose(arm: .rising), duration: 0.11),
           SproutFrame(pose: SproutPose(), duration: 0.5)]
        + sproutBlink
}()

/// The left arm, as [row, column] pixels on the same grid. It only shows up
/// mid-scratch, and stands one pixel off the body (the grid's blank column 1)
/// so it reads as an arm, not a thicker outline.
private func sproutArm(_ arm: SproutPose.Arm) -> [[Int]] {
    let raised = [[9, 1], [8, 0], [7, 0], [6, 0]]
    switch arm {
    case .down: return []
    case .rising: return raised
    case .scratchLow: return raised + [[5, 0], [4, 1], [3, 2], [3, 3]]
    case .scratchHigh: return raised + [[5, 0], [4, 1], [3, 2], [2, 3], [2, 4]]
    }
}

/// A template image: shape only, no color of its own, so AppKit tints it to
/// match the menu bar text in any theme.
///
/// One grid pixel is one point (two device pixels on Retina), which keeps the
/// pixel art crisp. Blank columns are trimmed so the number sits right next to
/// it, but room for the arm is always kept so the number never shifts mid-scratch.
func sproutIcon(fill: Double?, tired: Bool = false, sweating: Bool = false,
                pose: SproutPose = SproutPose()) -> NSImage {
    let rows = sproutPixels.map(Array.init)
    let bodyRows = rows.indices.filter { rows[$0].contains("b") }
    let fraction = min(max(fill ?? 0, 0), 100) / 100
    let filledCount = Int((fraction * Double(bodyRows.count)).rounded())
    let filledRows = Set(bodyRows.suffix(filledCount))

    func isEdge(_ y: Int, _ x: Int) -> Bool {
        [(y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)].contains { ny, nx in
            !rows.indices.contains(ny) || !rows[ny].indices.contains(nx) || rows[ny][nx] == "."
        }
    }

    let eyeRows = rows.indices.filter { rows[$0].contains("e") }
    /// Where the eyes are in the resting pose; looking around shifts them.
    func isOpenEye(_ y: Int, _ x: Int) -> Bool {
        rows.indices.contains(y) && rows[y].indices.contains(x) && rows[y][x] == "e"
    }
    func isEye(_ y: Int, _ x: Int) -> Bool {
        switch pose.eyes {
        // Tired: heavy lids, so each eye is a slit. A tired blink shuts it.
        case .open: return rows[y][x] == "e" && (!tired || y == eyeRows.last)
        case .closed: return rows[y][x] == "e" && y == eyeRows.last && !tired
        case .lookingUp: return isOpenEye(y + 1, x)
        case .lookingDown: return isOpenEye(y - 1, x)
        case .lookingDownLeft: return isOpenEye(y - 1, x + 1)
        case .lookingDownRight: return isOpenEye(y - 1, x - 1)
        }
    }
    let arm = sproutArm(pose.arm)
    /// A drop of sweat off the top right of the head, clear of the body.
    let sweatDrop = [[2, 17], [3, 17]]

    let usedColumns = rows.flatMap { row in row.indices.filter { row[$0] != "." } }
        + SproutPose.Arm.allCases.flatMap(sproutArm).map { $0[1] }
        + sweatDrop.map { $0[1] }
    let firstColumn = usedColumns.min() ?? 0, lastColumn = usedColumns.max() ?? 0

    let image = NSImage(size: NSSize(width: lastColumn - firstColumn + 1, height: rows.count),
                        flipped: true) { _ in
        NSColor.black.setFill()
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() {
                let solid: Bool
                if arm.contains([y, x]) || (sweating && sweatDrop.contains([y, x])) {
                    solid = true
                } else {
                    switch pixel {
                    case "#": solid = true
                    case "b", "e":
                        solid = isEye(y, x) ? !filledRows.contains(y)
                                            : filledRows.contains(y) || isEdge(y, x)
                    default: solid = false
                    }
                }
                if solid { NSRect(x: x - firstColumn, y: y, width: 1, height: 1).fill() }
            }
        }
        return true
    }
    image.isTemplate = true
    return image
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
    private var idleTimer: Timer?
    private var nextBigMove = Date().addingTimeInterval(.random(in: sproutMoveInterval))
    private var scratchesNext = Bool.random()
    private var pose = SproutPose()
    private let loadSampler = MacLoadSampler()
    private lazy var macLoad = loadSampler.sample()
    private var loadTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        statusItem.button?.imagePosition = .imageLeading

        refresh()
        startWatching()
        scheduleNextMove()

        // Backstop for the file watch, and it keeps the "updated N ago" text honest.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Sprout follows the Mac's load. A few cheap system reads every 5
        // seconds; the process list is only read when the menu is built.
        loadTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.macLoad = self.loadSampler.sample(interval: 5)
            self.statusItem.button?.image = self.currentSprout()
        }
        loadTimer?.tolerance = 1
    }

    // MARK: Display

    @objc func refresh() {
        let log = loadLog()
        let reading = loadReading(from: log.samples)
        let health = reading.map { dataHealth(figureAt: $0.sampledAt, lastPollAt: log.lastPollAt) }
        renderTitle(reading, health: health)
        rebuildMenu(reading, log: log, health: health)
    }

    private func renderTitle(_ reading: Reading?, health: DataHealth?) {
        guard let button = statusItem.button else { return }

        // The icon is a template image, so it always matches the menu bar's own
        // text color automatically — no manual color logic needed for it, in any
        // theme. Only the percentage text carries the warning color. With no
        // reading yet, Sprout shows empty.
        let config = loadConfig()
        let log = loadLog()
        let headlineReset = reading?.headline.map {
            likelyResetSinceLastFigure(key: $0.key, samples: log.samples, config: config)
        } ?? false
        button.image = currentSprout()

        guard let reading, let headline = reading.headline else {
            button.attributedTitle = styled(" —", color: .secondaryLabelColor)
            button.alphaValue = 0.5
            button.toolTip = "No usage figures recorded yet. Claude Desktop logs one when it starts."
            return
        }

        let used = headline.percentUsed
        let color: NSColor = headlineReset ? .secondaryLabelColor
            : used >= 90 ? .systemRed : used >= 75 ? .systemOrange : .labelColor
        // The tag matters: orgs differ, and "23%" alone reads as a monthly budget
        // even when it's a 5-hour window.
        let tag = cadenceTag(forKey: headline.key, config: config)
        let number = headlineReset ? " —" : " \(Int(used.rounded()))%"
        let title = NSMutableAttributedString(attributedString: styled(number, color: color))
        title.append(styled(" \(tag)", color: dimmed(color, alpha: 0.5)))
        button.attributedTitle = title
        button.alphaValue = (health?.shouldDim ?? false) ? 0.5 : 1.0
        button.toolTip = headlineReset
            ? "\(label(forMeterKey: headline.key)) has likely reset since the last figure (was \(Int(used.rounded()))%)"
            : usedLine(key: headline.key, percent: used)
    }

    private func currentSprout() -> NSImage {
        sproutIcon(fill: macLoad.score, tired: macLoad.tired, sweating: macLoad.sweating, pose: pose)
    }

    /// `withAlphaComponent` on a dynamic color like `.labelColor` pins it to the
    /// app's appearance (light, so dark grey), not the menu bar's (often dark, so
    /// white). Resolving inside a dynamic provider defers that to draw time, so the
    /// dimmed color follows the menu bar just like the undimmed one does.
    private func dimmed(_ color: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? color
            }
            return resolved.withAlphaComponent(alpha)
        }
    }

    private func styled(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
    }

    /// A non-interactive menu row that actually looks readable. `NSMenuItem.isEnabled
    /// = false` was the previous approach, but that's exactly what triggers macOS's
    /// low-contrast "disabled" text rendering — it's meant for controls that can't be
    /// clicked right now, not status text. A custom view sidesteps that rendering
    /// entirely, so an explicit color (severity coloring for the pace verdict, plain
    /// label color otherwise) actually shows instead of being overridden.
    private func infoItem(_ text: String, color: NSColor = .labelColor) -> NSMenuItem {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = color
        label.sizeToFit()

        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 3
        label.frame.origin = NSPoint(x: horizontalPadding, y: verticalPadding)

        let container = NSView(frame: NSRect(x: 0, y: 0,
                                              width: label.frame.width + horizontalPadding * 2,
                                              height: label.frame.height + verticalPadding * 2))
        container.addSubview(label)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func rebuildMenu(_ reading: Reading?, log: UsageLog, health: DataHealth?) {
        let menu = statusItem.menu!
        menu.removeAllItems()

        func info(_ text: String, color: NSColor = .labelColor) {
            menu.addItem(infoItem(text, color: color))
        }

        guard let reading, let headline = reading.headline else {
            info("No usage data yet")
            info("Claude Desktop logs a figure when it starts")
            addMacSection(to: menu)
            addControls(to: menu)
            return
        }

        let config = loadConfig()
        let used = headline.percentUsed
        info(limitsSummary(meterKeys: Array(reading.meters.keys), config: config), color: .secondaryLabelColor)
        func meterLine(_ key: String, _ percent: Double) {
            if likelyResetSinceLastFigure(key: key, samples: log.samples, config: config) {
                info("\(label(forMeterKey: key)): reset since last figure (was \(Int(percent.rounded()))%)",
                     color: .secondaryLabelColor)
            } else {
                info(usedLine(key: key, percent: percent))
            }
        }
        meterLine(headline.key, used)

        // Anything beyond the headline meter, shown rather than hidden.
        for (key, otherUsed) in reading.meters.sorted(by: { cadenceOrder($0.key) < cadenceOrder($1.key) })
        where key != headline.key {
            meterLine(key, otherUsed)
        }

        menu.addItem(.separator())
        addPaceSection(to: menu, info: info, currentPercent: used, samples: log.samples,
                       meterKey: headline.key, config: config)

        menu.addItem(.separator())

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        info("Figure from \(formatter.localizedString(for: reading.sampledAt, relativeTo: Date()))",
             color: .secondaryLabelColor)
        if let org = log.org {
            // Budgets are per org, so say which one these figures belong to.
            info("Org \(org.prefix(8))", color: .secondaryLabelColor)
        }

        switch health {
        case .notPolling, .figureLagging:
            // Claude Desktop now checks usage only when it starts (unless its own
            // menu bar panel is opened daily), so this is expected, not a fault.
            info("Claude Desktop sends new figures when it starts up", color: .secondaryLabelColor)
        case .fresh, .none:
            break
        }

        addMacSection(to: menu)
        addControls(to: menu, reading: reading)
    }

    private func addMacSection(to menu: NSMenu) {
        menu.addItem(.separator())
        for line in macLoadLines(macLoad, takeProcessSnapshot()) {
            menu.addItem(infoItem(line.text, color: line.emphasis ? macLoad.color : .secondaryLabelColor))
        }
    }

    /// The "am I trending over or under" readout, kept to two lines: a verdict with
    /// the number that matters most for it, then the raw rate for anyone who wants it.
    private func addPaceSection(to menu: NSMenu, info: (String, NSColor) -> Void, currentPercent: Double,
                                 samples: [Sample], meterKey: String, config: Config) {
        let meterCycle = meterInfo(forKey: meterKey).cycle
        guard let pace = computePace(currentPercent: currentPercent, samples: samples,
                                      meterKey: meterKey, config: config) else {
            switch meterCycle {
            case .unknown: info("Pace: unknown reset for \"\(meterKey)\"", .secondaryLabelColor)
            case .window: info("Pace: picks up again with the next figure", .secondaryLabelColor)
            case .billing: info("Pace: not enough data yet", .secondaryLabelColor)
            }
            return
        }

        let isWindow: Bool
        if case .window = meterCycle { isWindow = true } else { isWindow = false }
        let noun = isWindow ? "limit" : "cap"
        let resets = shortDuration(pace.secondsRemaining)

        let result = verdict(currentPercent: currentPercent, projectedEndPercent: pace.projectedEndPercent)
        switch result {
        case .alreadyOver:
            info("\(result.mark) Already over — resets in ~\(resets)", result.color)
        case .trendingOver:
            if let exhaustionDate = pace.exhaustionDate {
                info("\(result.mark) On pace to hit the \(noun) in ~\(shortDuration(exhaustionDate.timeIntervalSinceNow))",
                     result.color)
            } else {
                info("\(result.mark) \(result.label(noun)) (~\(Int(pace.projectedEndPercent))% by reset)", result.color)
            }
        case .cuttingItClose, .trendingUnder:
            info("\(result.mark) \(result.label(noun)) (~\(Int(pace.projectedEndPercent))% by reset)", result.color)
        }
        // Windows are short enough that %/day would read as alarming nonsense.
        let rate = isWindow
            ? String(format: "%.1f%%/hr", pace.dailyRatePercent / 24)
            : String(format: "%.0f%%/day", pace.dailyRatePercent)
        info("\(rate) · resets in ~\(resets)", .secondaryLabelColor)
    }

    private func addControls(to menu: NSMenu, reading: Reading? = nil) {
        menu.addItem(.separator())

        // Only worth offering when there's more than one limit to choose between.
        if let reading, let headline = reading.headline, reading.meters.count > 1 {
            menu.addItem(infoItem("Show in Menu Bar", color: .secondaryLabelColor))
            for key in reading.meters.keys.sorted(by: { cadenceOrder($0) < cadenceOrder($1) }) {
                let item = NSMenuItem(title: label(forMeterKey: key),
                                      action: #selector(pickMeter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                item.state = key == headline.key ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
            .target = self

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin() ? .on : .off
        menu.addItem(login)

        let animate = NSMenuItem(title: "Animate Sprout",
                                 action: #selector(toggleAnimation),
                                 keyEquivalent: "")
        animate.target = self
        animate.state = animateSprout ? .on : .off
        menu.addItem(animate)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func pickMeter(_ sender: NSMenuItem) {
        preferredMeterKey = sender.representedObject as? String
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchesAtLogin())
        refresh()
    }

    @objc private func toggleAnimation() {
        animateSprout.toggle()
        scheduleNextMove()
        refresh()
    }

    // MARK: Sprout's idle moves

    /// A blink every 4-9 seconds, and every 10-15 seconds a bigger move: a head
    /// scratch or a glance around the screen, taking turns. One timer per move,
    /// not a frame loop, so Sprout costs nothing between moves. Stays still when
    /// Reduce Motion is on or "Animate Sprout" is off.
    private func scheduleNextMove() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard animateSprout else { return }
        let blinkAt = Date().addingTimeInterval(.random(in: 4...9))
        // A tired Sprout only blinks: no energy for scratching or looking around.
        let bigMove = nextBigMove <= blinkAt && !macLoad.tired
        let timer = Timer(fire: bigMove ? nextBigMove : blinkAt, interval: 0,
                          repeats: false) { [weak self] _ in
            guard let self else { return }
            var frames = sproutBlink
            if bigMove {
                frames = self.scratchesNext ? sproutScratch : sproutGlance
                self.scratchesNext.toggle()
                self.nextBigMove = Date().addingTimeInterval(.random(in: sproutMoveInterval))
            }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                return self.scheduleNextMove()
            }
            self.play(frames) { self.scheduleNextMove() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func play(_ frames: [SproutFrame], then done: @escaping () -> Void) {
        guard let frame = frames.first else { return done() }
        pose = frame.pose
        statusItem.button?.image = currentSprout()
        DispatchQueue.main.asyncAfter(deadline: .now() + frame.duration) { [weak self] in
            self?.play(Array(frames.dropFirst()), then: done)
        }
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

/// CPU busy share needs two samples, so this takes a short look first.
func printMacLoad() {
    let sampler = MacLoadSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let load = sampler.sample(interval: 1)
    print("")
    for line in macLoadLines(load, takeProcessSnapshot()) { print(line.text) }
}

// `--dump` runs the same read path as the menu bar and prints the result, for
// checking the numbers or piping them somewhere else.
if CommandLine.arguments.contains("--dump") {
    let log = loadLog()
    let samples = log.samples
    guard let reading = loadReading(from: samples), let headline = reading.headline else {
        print("no usage data in \(usageLogPath)")
        printMacLoad()
        exit(1)
    }
    let config = loadConfig()
    let used = headline.percentUsed
    let health = dataHealth(figureAt: reading.sampledAt, lastPollAt: log.lastPollAt)
    print("org:        \(log.org ?? "none")")
    print(String(format: "used:       %.0f%%", used))
    print("\(limitsSummary(meterKeys: Array(reading.meters.keys), config: config))")
    print("headline:   \(label(forMeterKey: headline.key)) (\(headline.key)), shown as \(cadenceTag(forKey: headline.key, config: config))")
    print("meters:     \(reading.meters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    print("figure at:  \(reading.sampledAt)")
    print("last poll:  \(log.lastPollAt.map { "\($0)" } ?? "never")")
    print("health:     \(health)")
    for key in reading.meters.keys.sorted()
    where likelyResetSinceLastFigure(key: key, samples: samples, config: config) {
        print("reset:      \(key) has likely reset since its last figure")
    }

    if let pace = computePace(currentPercent: used, samples: samples, meterKey: headline.key, config: config) {
        let result = verdict(currentPercent: used, projectedEndPercent: pace.projectedEndPercent)
        print("pace:       \(String(format: "%.2f", pace.dailyRatePercent))%/day (\(pace.rateBasis))")
        print("  average:  \(String(format: "%.2f", pace.averageRatePercent))%/day since cycle start")
        if let recentRate = pace.recentRatePercent {
            print("  last 3h:  \(String(format: "%.2f", recentRate))%/day")
        }
        print(String(format: "projected:  %.0f%% by reset (in ~%@, at %@)",
                      pace.projectedEndPercent, shortDuration(pace.secondsRemaining), "\(pace.cycleEnd)"))
        print("verdict:    \(result.mark) \(result.label(headline.key == "xu" ? "cap" : "limit"))")
        if let exhaustionDate = pace.exhaustionDate {
            print("exhausts:   \(exhaustionDate)")
        }
    } else {
        print("pace:       not enough data yet")
    }
    printMacLoad()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

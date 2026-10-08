import Cocoa

// Sprout — a menu bar critter that shows how hard your Mac is working, and which
// app or Claude Code session is making it work. Its body fills as the Mac gets
// busier; it droops when strained and sweats when overloaded.
//
// Everything is read locally from the system (CPU ticks, memory pressure, swap,
// thermal state, the process list). No network, no credentials.

// MARK: - Mac load
//
// How hard the Mac is working, as one 0-100 score, plus what's causing it. The
// part Activity Monitor can't do: busy processes are traced back to the Claude
// Code session (and project) that started them.

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

    /// Brighter than the system orange and red: macOS mutes colors in the menu
    /// bar, and the system ones fade to tan and brick on a tinted bar.
    static let strainedColor = NSColor(srgbRed: 1.0, green: 0.6, blue: 0.1, alpha: 1)
    static let overloadedColor = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.22, alpha: 1)

    /// Only a strained Mac gets color, so color always means "something's wrong".
    var tint: NSColor? { score >= 90 ? Self.overloadedColor : score >= 75 ? Self.strainedColor : nil }
    var color: NSColor { tint ?? .labelColor }

    /// Sprout droops at "Strained", and sweats at "Overloaded".
    var tired: Bool { score >= 75 }
    var sweating: Bool { score >= 90 }

    /// How hard Sprout runs when overloaded, 0-1: how far past 90 the score
    /// is, or how far past one task per core the queue is (up to 4 per core),
    /// whichever is more. The score tops out at 100; the queue doesn't.
    var runIntensity: Double {
        let byScore = (score - 90) / 10
        let byQueue = (loadAverage / Double(max(cores, 1)) - 1) / 3
        return min(max(max(byScore, byQueue), 0), 1)
    }
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
    /// Seconds since it started.
    var elapsed: TimeInterval
    var path: String
}

/// What's using the Mac, grouped the way a person thinks about it: by app, or by
/// the Claude session that started the work.
struct LoadGroup {
    var label: String
    var cpu: Double
    var memoryKB: Double
    /// For a Claude session's row: its busiest command, which can be stopped.
    var command: SessionCommand?
}

/// A command a Claude Code session ran (always through a shell). Stopping it
/// means stopping the shell and everything under it.
struct SessionCommand {
    var shellPID: Int32
    var text: String
    var cpu: Double
    var elapsed: TimeInterval
    /// Commands normally finish in minutes. One running this long is usually a
    /// wait loop or a run that hung, not real work.
    var looksStuck: Bool { elapsed > 60 * 60 }
}

struct ClaudeSession {
    var pid: Int32
    var id: String?
    var title: String
    var lastActivity: Date?
    var cpu: Double
    var memoryKB: Double
    var commands: [SessionCommand]
    /// Another process is running the same session: one of them is left over.
    var runningTwice = false

    var status: String {
        var parts: [String] = []
        if let lastActivity {
            let idle = Date().timeIntervalSince(lastActivity)
            parts.append(idle < 10 * 60 ? "active" : "idle \(roughDuration(idle))")
        }
        if runningTwice { parts.append("running twice") }
        return parts.joined(separator: " · ")
    }
}

struct ProcessSnapshot {
    var groups: [LoadGroup]
    var sessions: [ClaudeSession]
    var sessionMemoryKB: Double { sessions.reduce(0) { $0 + $1.memoryKB } }
}

/// "40m", "3h", "2d".
func roughDuration(_ seconds: TimeInterval) -> String {
    if seconds >= 2 * 86400 { return "\(Int(seconds / 86400))d" }
    if seconds >= 90 * 60 { return "\(Int((seconds / 3600).rounded()))h" }
    return "\(max(1, Int((seconds / 60).rounded())))m"
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

/// ps's elapsed time: "[[dd-]hh:]mm:ss".
func parseElapsed(_ text: Substring) -> TimeInterval {
    var days = 0.0
    var clock = text
    if let dash = text.firstIndex(of: "-") {
        days = Double(text[..<dash]) ?? 0
        clock = text[text.index(after: dash)...]
    }
    let seconds = clock.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    return days * 86400 + seconds
}

func listProcesses() -> [ProcessEntry] {
    // comm last: it's the full executable path, which can contain spaces.
    runCommand("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,rss=,etime=,comm="])
        .split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6, let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]), let rss = Double(parts[3]) else { return nil }
            return ProcessEntry(pid: pid, ppid: ppid, cpu: cpu, memoryKB: rss,
                                elapsed: parseElapsed(parts[4]), path: String(parts[5]))
        }
}

/// A Claude Code session: the Code tab in Claude Desktop runs one under
/// Application Support, the terminal one under ~/.local/share/claude.
func isClaudeCodeSession(_ path: String) -> Bool {
    (path.contains("/claude-code/") && path.hasSuffix("/claude"))
        || path.contains("/.local/share/claude/versions/")
}

func isShell(_ path: String) -> Bool {
    ["zsh", "bash", "sh"].contains((path as NSString).lastPathComponent)
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

func shortTitle(_ title: String) -> String {
    title.count > 34 ? String(title.prefix(33)) + "…" : title
}

/// A process's command line. Only ever shown shortened, and never read for a
/// Claude session itself beyond its session ID.
func commandLine(of pid: Int32) -> String {
    runCommand("/bin/ps", ["-o", "args=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "Google Chrome" for anything inside Google Chrome.app, helpers included;
/// the file name for anything else.
func appName(forPath path: String) -> String {
    if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
        let name = String(app.dropLast(4))
        // Plain "Claude" reads like one of the Claude Code session rows.
        return name == "Claude" ? "Claude Desktop" : name
    }
    return (path as NSString).lastPathComponent
}

// MARK: Which session is which
//
// A resumed session names its ID in its arguments. A new one doesn't, but Claude
// Code makes a scratch folder named after the session ID within a second of
// starting, so the folder born closest to the process's start is its ID. The
// title and last activity come from Claude Code's transcript for that ID.
// Nothing else is read: in particular not the processes' environment, which
// holds login tokens.

let uuidPattern = try! NSRegularExpression(
    pattern: "--(?:resume|session-id)[= ]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")

/// A process's session never changes, so it's looked up once.
private var sessionIDCache: [Int32: (start: Date, id: String?)] = [:]

func sessionID(pid: Int32, startedAt start: Date) -> String? {
    if let cached = sessionIDCache[pid], abs(cached.start.timeIntervalSince(start)) < 5 { return cached.id }
    let id = findSessionID(pid: pid, startedAt: start)
    sessionIDCache[pid] = (start, id)
    return id
}

private func findSessionID(pid: Int32, startedAt start: Date) -> String? {
    let args = commandLine(of: pid)
    if let match = uuidPattern.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
       let range = Range(match.range(at: 1), in: args) {
        return String(args[range])
    }
    let fm = FileManager.default
    let scratchRoot = "/private/tmp/claude-\(getuid())"
    var best: (id: String, gap: TimeInterval)?
    for project in (try? fm.contentsOfDirectory(atPath: scratchRoot)) ?? [] {
        let projectPath = "\(scratchRoot)/\(project)"
        for entry in (try? fm.contentsOfDirectory(atPath: projectPath)) ?? [] where entry.count == 36 {
            guard let born = (try? fm.attributesOfItem(atPath: "\(projectPath)/\(entry)"))?[.creationDate] as? Date
            else { continue }
            let gap = born.timeIntervalSince(start)
            if gap > -5, gap < 120, gap < (best?.gap ?? .infinity) { best = (entry, gap) }
        }
    }
    return best?.id
}

/// Titles, cached until the transcript changes: transcripts run to megabytes.
private var titleCache: [String: (modified: Date, title: String)] = [:]

func transcriptPath(for id: String) -> String? {
    let root = NSString(string: "~/.claude/projects").expandingTildeInPath
    for project in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
        let path = "\(root)/\(project)/\(id).jsonl"
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    return nil
}

/// The session's name as Claude Desktop shows it: a title you set, else the one
/// Claude gave it.
func sessionTitle(transcript path: String, modified: Date) -> String {
    if let cached = titleCache[path], cached.modified == modified { return cached.title }
    // Only the last title entry of each kind matters, so search the raw bytes
    // from the end and parse just that one line. Decoding the whole transcript
    // took seconds on a big one.
    func lastTitle(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              let hit = data.range(of: Data("\"\(key)\":".utf8), options: .backwards) else { return nil }
        let newline = UInt8(ascii: "\n")
        let start = data[..<hit.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
        let end = data[hit.upperBound...].firstIndex(of: newline) ?? data.endIndex
        let object = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any]
        return object?[key] as? String
    }
    let title = lastTitle("customTitle") ?? lastTitle("aiTitle") ?? "Untitled session"
    titleCache[path] = (modified, title)
    return title
}

func takeProcessSnapshot() -> ProcessSnapshot {
    let processes = listProcesses()
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    let children = Dictionary(grouping: processes, by: \.ppid)

    func tree(_ pid: Int32) -> [ProcessEntry] {
        guard let root = byPID[pid] else { return [] }
        return [root] + (children[pid] ?? []).flatMap { tree($0.pid) }
    }

    // Claude sessions first: each one's commands, and everything under it.
    var sessions: [ClaudeSession] = []
    var claimed = Set<Int32>()
    for process in processes where isClaudeCodeSession(process.path) {
        let all = tree(process.pid)
        all.forEach { claimed.insert($0.pid) }

        let commands: [SessionCommand] = (children[process.pid] ?? []).filter { isShell($0.path) }.map { shell in
            let work = tree(shell.pid)
            let command = (children[shell.pid] ?? []).first
            // A loop that waits for something shows as its current `sleep`; it
            // gives itself away by being much older than that sleep.
            let text = command.map { child in
                (child.path as NSString).lastPathComponent == "sleep" && shell.elapsed - child.elapsed > 2
                    ? "a wait loop" : shortCommand(commandLine(of: child.pid))
            } ?? "shell"
            return SessionCommand(shellPID: shell.pid,
                                  text: text,
                                  cpu: work.reduce(0) { $0 + $1.cpu },
                                  elapsed: shell.elapsed)
        }

        let id = sessionID(pid: process.pid, startedAt: Date().addingTimeInterval(-process.elapsed))
        var title = "Untitled session"
        var lastActivity: Date?
        if let id, let path = transcriptPath(for: id),
           let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            title = sessionTitle(transcript: path, modified: modified)
            lastActivity = modified
        } else if let folder = workingDirectory(of: process.pid) {
            title = "Session in \((folder as NSString).lastPathComponent)"
        }
        sessions.append(ClaudeSession(pid: process.pid, id: id, title: title, lastActivity: lastActivity,
                                      cpu: all.reduce(0) { $0 + $1.cpu },
                                      memoryKB: all.reduce(0) { $0 + $1.memoryKB },
                                      commands: commands.sorted { $0.cpu > $1.cpu }))
    }
    let idCounts = Dictionary(grouping: sessions.compactMap(\.id), by: { $0 }).mapValues(\.count)
    for i in sessions.indices where (sessions[i].id.map { idCounts[$0] ?? 0 } ?? 0) > 1 {
        sessions[i].runningTwice = true
    }
    sessions.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }

    // Then everything else, by app.
    var groups: [String: LoadGroup] = [:]
    for process in processes where !claimed.contains(process.pid) && process.pid != getpid() {
        let name = appName(forPath: process.path)
        var group = groups[name] ?? LoadGroup(label: name, cpu: 0, memoryKB: 0)
        group.cpu += process.cpu
        group.memoryKB += process.memoryKB
        groups[name] = group
    }
    for session in sessions {
        let busiest = session.commands.first.flatMap { $0.cpu >= 10 ? $0 : nil }
        var label = "Claude · \(shortTitle(session.title))"
        if let busiest { label += ": \(busiest.text)" }
        groups["claude:\(session.pid)"] = LoadGroup(label: label, cpu: session.cpu,
                                                    memoryKB: session.memoryKB, command: busiest)
    }

    return ProcessSnapshot(groups: groups.values.sorted { $0.cpu > $1.cpu }, sessions: sessions)
}

/// Stops a command a Claude session ran: the shell and everything under it,
/// deepest first. Re-checked against a fresh process list first, so a reused
/// process ID can never take down something else.
@discardableResult
func stopCommand(shellPID: Int32) -> Bool {
    let processes = listProcesses()
    guard let shell = processes.first(where: { $0.pid == shellPID }), isShell(shell.path),
          let parent = processes.first(where: { $0.pid == shell.ppid }), isClaudeCodeSession(parent.path)
    else { return false }
    let children = Dictionary(grouping: processes, by: \.ppid)
    func deepestFirst(_ pid: Int32) -> [Int32] {
        (children[pid] ?? []).flatMap { deepestFirst($0.pid) } + [pid]
    }
    for pid in deepestFirst(shellPID) { kill(pid, SIGTERM) }
    return true
}

/// "1.4 cores", "40% of a core".
func coresText(_ cpuPercent: Double) -> String {
    cpuPercent >= 95 ? String(format: "%.1f cores", cpuPercent / 100) : "\(Int(cpuPercent.rounded()))% of a core"
}

func gigabytes(_ kilobytes: Double) -> String { String(format: "%.1f GB", kilobytes / 1_048_576) }

/// The top of the menu: how the Mac is doing overall.
func summaryLines(_ load: MacLoad) -> [String] {
    var lines = ["\(load.level) · \(Int(load.score.rounded()))%",
                 String(format: "CPU %.0f%% busy · %.0f tasks for %d cores",
                        load.cpuPercent, load.loadAverage, load.cores)]
    var memory = "Memory pressure \(load.memoryPressure.label)"
    if load.swapTotalGB > 0 {
        memory += String(format: " · swap %.1f of %.0f GB", load.swapUsedGB, load.swapTotalGB)
    }
    lines.append(memory)
    if load.thermal == .serious || load.thermal == .critical {
        lines.append("Running hot — macOS is slowing the chip down")
    }
    return lines
}

func busiestGroups(_ snapshot: ProcessSnapshot) -> [LoadGroup] {
    snapshot.groups.prefix(3).filter { $0.cpu >= 10 }
}

/// One line per command, for the sessions list: what, how hard, how long.
func commandLineText(_ command: SessionCommand) -> String {
    var text = "\(command.text) · running \(roughDuration(command.elapsed))"
    if command.cpu >= 10 { text += " · \(coresText(command.cpu))" }
    if command.looksStuck { text = "⚠︎ " + text + " — stuck?" }
    return text
}

/// Everything, as text, for `--dump`.
func dumpLines(_ load: MacLoad, _ snapshot: ProcessSnapshot) -> [String] {
    var lines = summaryLines(load)
    let busiest = busiestGroups(snapshot)
    if !busiest.isEmpty {
        lines.append("Busiest:")
        lines += busiest.map { "  \($0.label) · \(coresText($0.cpu))" }
    }
    if let biggest = snapshot.groups.max(by: { $0.memoryKB < $1.memoryKB }) {
        lines.append("Most memory: \(biggest.label) · \(gigabytes(biggest.memoryKB))")
    }
    if !snapshot.sessions.isEmpty {
        lines.append("Claude Code sessions: \(snapshot.sessions.count) · \(gigabytes(snapshot.sessionMemoryKB))")
        for session in snapshot.sessions {
            lines.append("  \(shortTitle(session.title)) · \(session.status)")
            lines += session.commands.map { "    " + commandLineText($0) }
        }
    }
    return lines
}

// MARK: - Menu bar icon

/// Sprout, the app's own pixel critter. Its body fills from the bottom as
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

/// The strained moves, layered on top of the pose: panting (the body sinks onto
/// its feet), a falling drop of sweat, and a shiver. Driven by `strainFrame(tick:)`.
struct StrainFrame: Equatable {
    enum Stride { case standing, apart, together }
    /// Body and head one pixel lower, squashed onto the feet.
    var sunk = false
    /// Where the sweat drop is on its way down; nil for none.
    var dropStep: Int?
    /// Running in place: feet apart, then together.
    var stride = Stride.standing
}

/// Feet mid-run, as [row, column] pixels: in place of the standing feet.
private let runningFeet: [StrainFrame.Stride: [[Int]]] = [
    .apart: [[14, 3], [14, 4], [14, 5], [14, 14], [14, 15], [14, 16],
             [15, 2], [15, 3], [15, 4], [15, 15], [15, 16], [15, 17]],
    .together: [[14, 5], [14, 6], [14, 7], [14, 11], [14, 12], [14, 13],
                [15, 5], [15, 6], [15, 7], [15, 11], [15, 12], [15, 13]],
]

/// The sweat drop's path: forming on the head, then falling down the clear
/// column beside the body, then gone before it re-forms.
private let sweatDropPath: [[[Int]]] = [
    [[2, 17], [3, 17]],
    [[3, 18], [4, 18]],
    [[6, 18], [7, 18]],
    [[9, 18], [10, 18]],
    [[12, 18]],
    [],
]

/// Strained: panting, ticks of 0.15 s, a ~1 s breath (sunk 2 ticks of 7).
/// Overloaded: running in place, one stride per tick, landing sunk on each
/// apart step, with sweat dripping. The harder the Mac works, the shorter the
/// tick: 0.32 s a stride at the edge of overloaded, 0.08 s flat out.
func strainTick(running: Bool, intensity: Double) -> TimeInterval {
    running ? 0.32 - 0.24 * intensity : 0.15
}

func strainFrame(tick: Int, running: Bool) -> StrainFrame {
    guard running else { return StrainFrame(sunk: tick % 7 < 2) }
    let apart = tick % 2 == 0
    let drip = tick % (sweatDropPath.count + 3)
    return StrainFrame(sunk: apart, dropStep: drip < sweatDropPath.count ? drip : 0,
                       stride: apart ? .apart : .together)
}

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
                pose: SproutPose = SproutPose(), strain: StrainFrame = StrainFrame(),
                tint: NSColor? = nil) -> NSImage {
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
    // Sweating but not animating: the drop sits on the head.
    let sweatDrop = sweating ? sweatDropPath[strain.dropStep ?? 0] : []
    let footRows = Set(rows.indices.filter { !rows[$0].contains("b") && rows[$0].contains("#") && $0 > 2 })

    // Room for every move is always kept (arm, drop path, running feet), so the
    // number beside Sprout never shifts.
    let usedColumns = rows.flatMap { row in row.indices.filter { row[$0] != "." } }
        + SproutPose.Arm.allCases.flatMap(sproutArm).map { $0[1] }
        + sweatDropPath.joined().map { $0[1] }
        + runningFeet.values.joined().map { $0[1] }
    let firstColumn = usedColumns.min() ?? 0, lastColumn = usedColumns.max() ?? 0
    let feet = runningFeet[strain.stride]

    let image = NSImage(size: NSSize(width: lastColumn - firstColumn + 1, height: rows.count),
                        flipped: true) { _ in
        (tint ?? .black).setFill()
        func plot(_ x: Int, _ y: Int) {
            NSRect(x: x - firstColumn, y: y, width: 1, height: 1).fill()
        }
        for pixel in sweatDrop { plot(pixel[1], pixel[0]) }
        for pixel in feet ?? [] { plot(pixel[1], pixel[0]) }
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() {
                let solid: Bool
                if arm.contains([y, x]) {
                    solid = true
                } else {
                    switch pixel {
                    case "#": solid = feet == nil || !footRows.contains(y)
                    case "b", "e":
                        solid = isEye(y, x) ? !filledRows.contains(y)
                                            : filledRows.contains(y) || isEdge(y, x)
                    default: solid = false
                    }
                }
                // Panting: everything above the feet drops a pixel onto them.
                if solid { plot(x, strain.sunk && !footRows.contains(y) ? y + 1 : y) }
            }
        }
        return true
    }
    image.isTemplate = tint == nil
    return image
}

// MARK: - Login item
//
// A LaunchAgent rather than SMAppService: this app is built locally and unsigned,
// and SMAppService registration is unreliable without a signed bundle.

let launchAgentPath = NSString(string: "~/Library/LaunchAgents/com.local.sprout.plist")
    .expandingTildeInPath

func launchesAtLogin() -> Bool { FileManager.default.fileExists(atPath: launchAgentPath) }

func setLaunchAtLogin(_ enabled: Bool) {
    let fm = FileManager.default
    if enabled {
        let executable = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": "com.local.sprout",
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
    private var loadTimer: Timer?
    private var idleTimer: Timer?
    private var nextBigMove = Date().addingTimeInterval(.random(in: sproutMoveInterval))
    private var scratchesNext = Bool.random()
    private var pose = SproutPose()
    private var strain = StrainFrame()
    private var strainTimer: Timer?
    private var strainTicks = 0
    private let loadSampler = MacLoadSampler()
    private lazy var macLoad = loadSampler.sample()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        statusItem.button?.imagePosition = .imageLeading

        // A few cheap system reads every 5 seconds; the process list is only
        // read when the menu opens.
        loadTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.macLoad = self.loadSampler.sample(interval: 5)
            self.renderTitle()
            self.updateStrainAnimation()
        }
        loadTimer?.tolerance = 1

        renderTitle()
        scheduleNextMove()
        updateStrainAnimation()
    }

    // MARK: Display

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        // Sprout is a template image, so macOS tints it to match the menu bar in
        // any theme. Only the number carries a warning color.
        // Each change makes macOS redraw the menu bar item, so skip no-ops.
        let image = currentSprout()
        if button.image !== image { button.image = image }
        let title = styled(" \(Int(macLoad.score.rounded()))%", color: macLoad.color)
        if button.attributedTitle != title { button.attributedTitle = title }
        button.toolTip = "Mac: \(macLoad.level.lowercased())"
    }

    /// Drawn frames, reused: an animation cycles through a handful of them.
    private var sproutCache: [String: NSImage] = [:]

    private func currentSprout() -> NSImage {
        // Fill only changes per body row, so key on the rows filled, not the score.
        let rowsFilled = Int((min(max(macLoad.score, 0), 100) / 100 * 12).rounded())
        let key = "\(rowsFilled) \(macLoad.tired) \(macLoad.sweating) \(pose.eyes) \(pose.arm) "
            + "\(strain.sunk) \(strain.dropStep ?? -1) \(strain.stride) \(macLoad.tint?.description ?? "-")"
        if let image = sproutCache[key] { return image }
        if sproutCache.count > 200 { sproutCache.removeAll() }
        let image = sproutIcon(fill: macLoad.score, tired: macLoad.tired, sweating: macLoad.sweating,
                               pose: pose, strain: strain, tint: macLoad.tint)
        sproutCache[key] = image
        return image
    }

    private func styled(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: color,
        ])
    }

    /// A non-interactive menu row that actually looks readable. A disabled
    /// NSMenuItem gets macOS's low-contrast "disabled" text; a custom view keeps
    /// the color we ask for.
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

    private func rebuildMenu() {
        let menu = statusItem.menu!
        menu.removeAllItems()

        let snapshot = takeProcessSnapshot()
        for (i, line) in summaryLines(macLoad).enumerated() {
            menu.addItem(infoItem(line, color: i == 0 ? macLoad.color : .secondaryLabelColor))
        }

        let busiest = busiestGroups(snapshot)
        if !busiest.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoItem("Busiest", color: .secondaryLabelColor))
            for group in busiest {
                let item = NSMenuItem(title: "\(group.label) · \(coresText(group.cpu))", action: nil, keyEquivalent: "")
                item.submenu = NSMenu()
                if let command = group.command {
                    item.submenu?.addItem(stopItem(command, session: group.label))
                } else {
                    let open = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor),
                                          keyEquivalent: "")
                    open.target = self
                    item.submenu?.addItem(open)
                }
                menu.addItem(item)
            }
        }
        if let biggest = snapshot.groups.max(by: { $0.memoryKB < $1.memoryKB }) {
            menu.addItem(infoItem("Most memory: \(biggest.label) · \(gigabytes(biggest.memoryKB))",
                                  color: .secondaryLabelColor))
        }

        if !snapshot.sessions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoItem("Claude Code sessions · \(snapshot.sessions.count) · "
                                  + gigabytes(snapshot.sessionMemoryKB), color: .secondaryLabelColor))
            for session in snapshot.sessions {
                let stuck = session.commands.contains(where: \.looksStuck)
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let title = NSMutableAttributedString(string: (stuck ? "⚠︎ " : "") + shortTitle(session.title),
                                                      attributes: [.font: NSFont.menuFont(ofSize: 0)])
                title.append(NSAttributedString(string: "  " + session.status, attributes: [
                    .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                item.attributedTitle = title
                // Every row gets a submenu, so idle sessions read as normal
                // rows rather than greyed-out ones.
                item.submenu = NSMenu()
                if session.commands.isEmpty {
                    item.submenu?.addItem(infoItem("Nothing running", color: .secondaryLabelColor))
                }
                for command in session.commands {
                    item.submenu?.addItem(infoItem(commandLineText(command),
                                                   color: command.looksStuck ? .systemOrange : .secondaryLabelColor))
                    item.submenu?.addItem(stopItem(command, session: session.title))
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin() ? .on : .off
        menu.addItem(login)

        let animate = NSMenuItem(title: "Animate Sprout", action: #selector(toggleAnimation), keyEquivalent: "")
        animate.target = self
        animate.state = animateSprout ? .on : .off
        menu.addItem(animate)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: Stopping a command

    private final class StopTarget: NSObject {
        let command: SessionCommand
        let session: String
        init(_ command: SessionCommand, _ session: String) { self.command = command; self.session = session }
    }

    private func stopItem(_ command: SessionCommand, session: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Stop “\(command.text)”…", action: #selector(confirmStop(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = StopTarget(command, session)
        return item
    }

    /// Always asks first: the Claude session sees its command end, which is
    /// usually fine but can lose a long run's results.
    @objc private func confirmStop(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? StopTarget else { return }
        let alert = NSAlert()
        alert.messageText = "Stop “\(target.command.text)”?"
        alert.informativeText = "It was started by Claude (\(target.session)) and has been running for "
            + "\(roughDuration(target.command.elapsed)). Claude will see the command end; the session "
            + "itself keeps going."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !stopCommand(shellPID: target.command.shellPID) {
            let gone = NSAlert()
            gone.messageText = "That command already finished."
            gone.runModal()
        }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchesAtLogin())
    }

    @objc private func toggleAnimation() {
        animateSprout.toggle()
        scheduleNextMove()
        updateStrainAnimation()
    }

    // MARK: Strained moves

    /// Panting while strained; dripping and shivering on top while overloaded.
    /// The frame timer only runs while the Mac is strained, so a calm Sprout
    /// costs nothing between its occasional fidgets.
    private func updateStrainAnimation() {
        let animate = macLoad.tired && animateSprout
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            strainTimer?.invalidate()
            strainTimer = nil
            if strain != StrainFrame() {
                strain = StrainFrame()
                statusItem.button?.image = currentSprout()
            }
            return
        }
        // Re-timed whenever the pace changes enough to notice.
        let running = macLoad.sweating
        let interval = strainTick(running: running, intensity: macLoad.runIntensity)
        if let current = strainTimer, abs(current.timeInterval - interval) < 0.02 { return }
        strainTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.strainTicks += 1
            let next = strainFrame(tick: self.strainTicks, running: self.macLoad.sweating)
            // Most ticks change nothing; only redraw when the frame does.
            guard next != self.strain else { return }
            self.strain = next
            self.statusItem.button?.image = self.currentSprout()
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        strainTimer = timer
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
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}

// `--dump` prints what the menu shows, for checking from a terminal. CPU busy
// share needs two samples, so it takes a one-second look first.
if CommandLine.arguments.contains("--dump") {
    let sampler = MacLoadSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let load = sampler.sample(interval: 1)
    for line in dumpLines(load, takeProcessSnapshot()) { print(line) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

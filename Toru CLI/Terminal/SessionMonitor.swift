import Foundation
import Darwin

/// Polls the live shell process so the SwiftUI status bar can mirror the
/// shell's actual state without injecting markers into the PTY stream.
///
/// Design points worth keeping in mind when editing:
///   - `proc_pidinfo` reads from a fixed-size C tuple. Take its bytes via
///     `withUnsafeBytes(of: copy)` (NOT `&info.pvi_cdir.vip_path`), since
///     in-place addressing of a nested tuple field can dangle.
///   - Timer fires on the main runloop. We're already `@MainActor`, so
///     handlers run on main without an extra `Task` hop.
///   - One in-flight detect Task at a time; new cwd cancels prior probe.
@MainActor
final class SessionMonitor: ObservableObject {
    static let shared = SessionMonitor()

    @Published private(set) var cwd: String = NSHomeDirectory()
    @Published private(set) var runtime: String = ""
    @Published private(set) var branch: String = ""
    @Published private(set) var dirty: Bool = false

    private var shellPid: pid_t = 0
    private var timer: Timer?
    private var lastPolledCwd: String = ""
    private var inflightDetect: Task<Void, Never>?

    private init() {}

    /// Hand off the PID of the running shell. Idempotent for same pid;
    /// re-attach with a different pid resets observed state so the chips
    /// don't briefly display stale values from a different tab's shell.
    func attach(pid: pid_t) {
        guard pid > 0 else { return }
        if pid == shellPid { return }
        shellPid = pid
        lastPolledCwd = ""
        cwd = NSHomeDirectory()
        runtime = ""
        branch = ""
        dirty = false
        inflightDetect?.cancel()
        startPolling()
        poll()
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        shellPid = 0
        inflightDetect?.cancel()
    }

    // MARK: - Poll loop

    private func startPolling() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            // Timer fires on the main runloop. The Swift 6 isolation
            // checker can't prove that statically, so wrap in
            // `assumeIsolated` to call the @MainActor-bound poll().
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard shellPid > 0 else { return }
        guard let path = Self.processCwd(pid: shellPid) else {
            // Process gone or cwd unreadable. Don't churn — leave existing
            // values in place.
            return
        }
        if path != lastPolledCwd {
            lastPolledCwd = path
            cwd = path
            triggerDetect(at: path)
        } else {
            // Same cwd — re-probe git only.
            triggerGitOnly(at: path)
        }
    }

    // MARK: - Async detectors

    private func triggerDetect(at path: String) {
        inflightDetect?.cancel()
        inflightDetect = Task { [weak self] in
            let rt = await Self.detectRuntime(cwd: path)
            let (br, drty) = await Self.detectGit(cwd: path)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.runtime = rt
                self?.branch = br
                self?.dirty = drty
            }
        }
    }

    private func triggerGitOnly(at path: String) {
        inflightDetect?.cancel()
        inflightDetect = Task { [weak self] in
            let (br, drty) = await Self.detectGit(cwd: path)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.branch = br
                self?.dirty = drty
            }
        }
    }

    // MARK: - libproc cwd lookup

    /// Returns the cwd of `pid` via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
    /// Copies the C tuple onto the stack first to guarantee a stable
    /// address inside `withUnsafeBytes`.
    private static func processCwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard bytes == Int32(size) else { return nil }

        // `vip_path` is a fixed-size C tuple (CChar × MAXPATHLEN). Copy it
        // onto the stack so withUnsafeBytes operates on a real address.
        let pathTuple = info.pvi_cdir.vip_path
        return withUnsafeBytes(of: pathTuple) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let cstr = base.assumingMemoryBound(to: CChar.self)
            let path = String(cString: cstr)
            return path.isEmpty ? nil : path
        }
    }

    // MARK: - Runtime / git probes (Process via /bin/zsh -lc)

    private static func detectRuntime(cwd: String) async -> String {
        let fm = FileManager.default
        let exists: (String) -> Bool = { fm.fileExists(atPath: "\(cwd)/\($0)") }
        if exists("package.json") || exists("node_modules") {
            if let v = await run("node --version", cwd: cwd) { return formatNode(v) }
        } else if exists("go.mod") {
            if let v = await run("go version", cwd: cwd) { return formatGo(v) }
        } else if exists("Cargo.toml") {
            if let v = await run("rustc --version", cwd: cwd) { return formatRust(v) }
        } else if exists("requirements.txt") || exists("pyproject.toml") {
            if let v = await run("python3 --version", cwd: cwd) { return formatPython(v) }
        } else if exists("Gemfile") {
            if let v = await run("ruby --version", cwd: cwd) { return formatRuby(v) }
        } else if exists("composer.json") {
            if let v = await run("php --version", cwd: cwd) { return formatPHP(v) }
        } else if exists("mix.exs") {
            if let v = await run("elixir --version", cwd: cwd) { return formatElixir(v) }
        }
        if let v = await run("node --version", cwd: cwd) { return formatNode(v) }
        return ""
    }

    private static func detectGit(cwd: String) async -> (String, Bool) {
        let branch = (await run("git branch --show-current", cwd: cwd)) ?? ""
        let porcelain = (await run("git status --porcelain", cwd: cwd)) ?? ""
        return (branch, !porcelain.isEmpty)
    }

    private static func run(_ command: String, cwd: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe; proc.standardError = errPipe
            do { try proc.run() } catch { return nil }
            // Drain stdout BEFORE waitUntilExit. Pipe buffer is ~16-64 KB;
            // if the child writes more than that, it blocks on write() and
            // waitUntilExit() blocks on the never-exiting child = deadlock
            // (zombie zsh per 0.6s tick on repos with many dirty files).
            // readDataToEndOfFile already blocks until EOF (child exit), so
            // waitUntilExit afterwards is the cheap call.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let s = String(data: outData, encoding: .utf8) else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.value
    }

    private static func formatNode(_ s: String) -> String {
        let v = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return "node \(v)"
    }
    private static func formatGo(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count >= 3 else { return "" }
        let v = parts[2].hasPrefix("go") ? String(parts[2].dropFirst(2)) : String(parts[2])
        return "go \(v)"
    }
    private static func formatRust(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return "rust \(parts[1])"
    }
    private static func formatPython(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return "py \(parts[1])"
    }
    private static func formatRuby(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return "ruby \(parts[1])"
    }
    private static func formatPHP(_ s: String) -> String {
        let firstLine = s.split(separator: "\n").first.map(String.init) ?? s
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return "php \(parts[1])"
    }
    private static func formatElixir(_ s: String) -> String {
        // "Erlang/OTP 26 ... \nElixir 1.16.0 (...)"
        for line in s.split(separator: "\n") {
            if line.hasPrefix("Elixir") {
                let parts = line.split(separator: " ")
                if parts.count >= 2 { return "elixir \(parts[1])" }
            }
        }
        return ""
    }
}

import Foundation

enum PTYBridge {
    /// Determines the shell to launch. Honors `$SHELL`, falls back to `/bin/zsh`.
    static func resolveShell() -> String {
        if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        return "/bin/zsh"
    }

    static func resolveHomeDirectory() -> String {
        NSHomeDirectory()
    }

    /// Build a typical login-shell environment.
    ///
    /// GUI-launched apps (Finder, Xcode debug) inherit a very sparse PATH —
    /// typically `/usr/bin:/bin:/usr/sbin:/sbin`. That's enough to find
    /// `/bin/zsh` itself but misses everything in `/opt/homebrew/bin`,
    /// `/usr/local/bin`, etc. Login zsh + `path_helper` will recover most
    /// of the standard paths once it runs, but commands invoked *before*
    /// any rc files load (or during a slow `.zshrc` source) hit the sparse
    /// PATH and fail. We pre-seed PATH with the common Homebrew + system
    /// directories so `node` / `npm` / `git` / `brew` work immediately.
    /// User-specific tooling (nvm, asdf, rbenv, …) still requires a
    /// working `~/.zshrc`.
    static func buildEnvironment(shell: String = resolveShell()) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TORU_SESSION"] = "1"
        env["PATH"] = enrichedPATH(existing: env["PATH"])

        if ShellEnvironment.isZsh(shell) {
            env["ZDOTDIR"] = ShellEnvironment.zdotdir()
        }
        return env
    }

    /// Prepend known-good directories to the inherited PATH (if not already
    /// present). Filters to ones that actually exist on this machine.
    private static func enrichedPATH(existing: String?) -> String {
        let candidates = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let fm = FileManager.default
        let presentDirs = candidates.filter { fm.fileExists(atPath: $0) }

        let inherited = (existing ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        var seen = Set<String>()
        var ordered: [String] = []
        for d in presentDirs + inherited where seen.insert(d).inserted {
            ordered.append(d)
        }
        return ordered.joined(separator: ":")
    }

    static func envArray(shell: String = resolveShell()) -> [String] {
        buildEnvironment(shell: shell).map { "\($0.key)=\($0.value)" }
    }
}

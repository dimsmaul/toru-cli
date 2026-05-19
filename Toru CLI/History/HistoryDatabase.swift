import Foundation
import GRDB

final class HistoryDatabase {
    static let shared: HistoryDatabase = {
        do { return try HistoryDatabase(url: HistoryDatabase.defaultURL()) }
        catch let diskErr {
            NSLog("[HistoryDatabase] disk init failed: \(diskErr); falling back to in-memory")
            do { return try HistoryDatabase.inMemory() }
            catch let memErr {
                NSLog("[HistoryDatabase] in-memory init also failed: \(memErr); history will not persist this session")
                return HistoryDatabase.disabled()
            }
        }
    }()

    private let queue: DatabaseQueue?
    private var lastInsertedCommand: String?

    init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    /// No-op fallback used when both the on-disk and in-memory DB init
    /// failed. Methods return empty results so the app keeps running
    /// without history persistence rather than trapping at startup.
    private init(disabled: Void) {
        self.queue = nil
    }

    static func disabled() -> HistoryDatabase {
        HistoryDatabase(disabled: ())
    }

    convenience init(url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "toru-cli-history"
        let q = try DatabaseQueue(path: url.path, configuration: config)
        try self.init(queue: q)
    }

    static func inMemory() throws -> HistoryDatabase {
        try HistoryDatabase(queue: try DatabaseQueue())
    }

    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("Toru CLI", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "commandHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("command",    .text).notNull()
                t.column("rawInput",   .text).notNull()
                t.column("directory",  .text).notNull()
                t.column("exitCode",   .integer).notNull().defaults(to: 0)
                t.column("executedAt", .datetime).notNull()
                t.column("sessionId",  .text).notNull()
            }
            try db.create(index: "idx_history_executedAt", on: "commandHistory", columns: ["executedAt"])
            try db.create(index: "idx_history_command",    on: "commandHistory", columns: ["command"])
        }
        return m
    }

    /// Insert with dedup rules: skip if same as previous, leading-space, or empty.
    @discardableResult
    func record(rawInput: String, executed command: String, directory: String, exitCode: Int = 0, sessionId: String) -> Bool {
        guard let queue else { return false }
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if rawInput.hasPrefix(" ") { return false }
        if let prev = lastInsertedCommand, prev == command { return false }

        var rec = CommandHistory(
            id: nil,
            command: command,
            rawInput: rawInput,
            directory: directory,
            exitCode: exitCode,
            executedAt: Date(),
            sessionId: sessionId
        )
        do {
            try queue.write { db in try rec.insert(db) }
            lastInsertedCommand = command
            return true
        } catch {
            return false
        }
    }

    /// Distinct commands ordered newest-first whose `command` starts with
    /// `prefix`. Empty prefix returns all distinct commands. Used by the
    /// input bar's up/down arrow navigation (Warp-style prefix recall).
    func recentMatching(prefix: String, limit: Int = 100) -> [String] {
        guard let queue else { return [] }
        let pattern = prefix.isEmpty ? "%" : "\(escapeLike(prefix))%"
        return (try? queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT command FROM (
                    SELECT command, MAX(executedAt) AS latest
                    FROM commandHistory
                    WHERE command LIKE ? ESCAPE '\\'
                    GROUP BY command
                    ORDER BY latest DESC
                    LIMIT ?
                )
                """, arguments: [pattern, limit])
        }) ?? []
    }

    func mostRecentMatching(prefix: String) -> String? {
        guard let queue else { return nil }
        guard !prefix.isEmpty else { return nil }
        return (try? queue.read { db in
            try CommandHistory
                .filter(Column("command").like("\(escapeLike(prefix))%"))
                .order(Column("executedAt").desc)
                .limit(1)
                .fetchOne(db)?
                .command
        }) ?? nil
    }

    func search(query: String, limit: Int = 8) -> [CommandHistory] {
        guard let queue else { return [] }
        guard !query.isEmpty else { return [] }
        let pattern = "%\(escapeLike(query))%"
        return (try? queue.read { db in
            try CommandHistory
                .filter(Column("command").like(pattern))
                .order(Column("executedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func recent(limit: Int = 100) -> [CommandHistory] {
        guard let queue else { return [] }
        return (try? queue.read { db in
            try CommandHistory
                .order(Column("executedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func clear() {
        guard let queue else { lastInsertedCommand = nil; return }
        _ = try? queue.write { db in
            try CommandHistory.deleteAll(db)
        }
        lastInsertedCommand = nil
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%",  with: "\\%")
         .replacingOccurrences(of: "_",  with: "\\_")
    }
}

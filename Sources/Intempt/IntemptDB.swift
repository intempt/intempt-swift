//
//  IntemptDB.swift
//  Intempt
//
//  Adapted from mixpanel-swift's MPDB.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Created by Jared McFarland on 7/2/21.
//  Copyright © 2021 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//
//    1. FAILURE CLASSIFICATION. Upstream calls `recreate()` — which deletes
//       the database file — on ANY sqlite failure, including a transient
//       SQLITE_BUSY or a lock contention. That turns a momentary conflict
//       into total loss of every queued event. Here only genuine corruption
//       (SQLITE_CORRUPT / SQLITE_NOTADB) recreates; BUSY/LOCKED retry; all
//       other errors fail the single operation and leave the store intact.
//
//    2. EMPTY-ID GUARD. Upstream's `idsSqlString([])` returns ")", producing
//       `WHERE id IN )`. That fails to prepare, which triggers recreate(),
//       which wipes the database — so deleting zero rows destroys the queue.
//       Deleting nothing is now a no-op.
//
//    3. SERIAL ACCESS. All access is funnelled through one serial queue, and
//       a busy_timeout is set as defence in depth. Upstream shares a single
//       connection across callers with no serialisation.
//
//    4. BACKUP EXCLUSION. `.libraryDirectory` is NOT excluded from iCloud/
//       iTunes backup by default (only Library/Caches is). The exclusion flag
//       is set explicitly so a user's backup does not carry the event queue.
//
import Foundation
import SQLite3

/// Which logical store a row belongs to. Intempt batches every model type
/// through one `/track` envelope, so events and consents are the only split.
enum PersistenceType: String, CaseIterable {
    case events
    case consents
}

final class IntemptDB {

    private var connection: OpaquePointer?
    private let queue = DispatchQueue(label: "com.intempt.db", qos: .utility)
    private let namespace: String
    private let directoryOverride: URL?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let dbFileName = "IntemptDB.sqlite"
    private static let busyTimeoutMs: Int32 = 5000

    /// - Parameter directoryOverride: test seam. Production passes nil and the
    ///   store lands in Library (iOS) / Caches (other platforms).
    init(namespace: String, directoryOverride: URL? = nil) {
        self.namespace = String(
            namespace.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        self.directoryOverride = directoryOverride
        queue.sync { openLocked() }
    }

    deinit {
        // Not via `queue.sync` — deinit may already run on that queue.
        sqlite3_close(connection)
        connection = nil
    }

    // MARK: - Paths

    private func databaseURL() -> URL? {
        let manager = FileManager.default
        let base: URL?
        if let directoryOverride {
            base = directoryOverride
        } else {
            #if os(iOS) || os(tvOS) || os(watchOS)
                base = manager.urls(for: .libraryDirectory, in: .userDomainMask).last
            #else
                base = manager.urls(for: .cachesDirectory, in: .userDomainMask).last
            #endif
        }
        guard !namespace.isEmpty else { return nil }
        return base?.appendingPathComponent("\(namespace)_\(Self.dbFileName)")
    }

    private func tableName(_ type: PersistenceType) -> String {
        "intempt_\(namespace)_\(type.rawValue)"
    }

    // MARK: - Open / close

    private func openLocked() {
        guard var url = databaseURL() else {
            IntemptLogger.shared.log(.error, "namespace is empty; database cannot be opened")
            return
        }

        #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            // Keeps the DB and its WAL/SHM readable in the background after
            // first unlock. Without it, a WAL fsync can hang while the screen
            // is locked and the watchdog kills the app. Inherited from upstream.
            let flags =
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
                | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #else
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        #endif

        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK else {
            IntemptLogger.shared.log(.error, "failed to open database at \(url.path)")
            sqlite3_close(connection)
            connection = nil
            return
        }

        sqlite3_busy_timeout(connection, Self.busyTimeoutMs)
        exec("PRAGMA journal_mode=WAL;")
        createTablesLocked()
        excludeFromBackup(&url)
    }

    /// `.libraryDirectory` is not backup-excluded by default — only
    /// Library/Caches is. Telemetry should never inflate a user's backup.
    private func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func createTablesLocked() {
        for type in PersistenceType.allCases {
            let table = tableName(type)
            exec(
                """
                CREATE TABLE IF NOT EXISTS \(table)(
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  data BLOB NOT NULL,
                  time REAL NOT NULL,
                  flag INTEGER NOT NULL DEFAULT 0
                );
                """)
            exec("CREATE INDEX IF NOT EXISTS idx_\(table)_time ON \(table) (time);")
        }
    }

    /// Only genuine corruption justifies destroying the store. Upstream
    /// recreates on every failure, including transient contention.
    private func handle(_ code: Int32, context: String) {
        switch code {
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            IntemptLogger.shared.log(.error, "\(context): database corrupt, recreating")
            recreateLocked()
        case SQLITE_BUSY, SQLITE_LOCKED:
            // busy_timeout already retried; surface it and keep the data.
            IntemptLogger.shared.log(.warning, "\(context): database busy, operation skipped")
        default:
            let msg = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
            IntemptLogger.shared.log(.warning, "\(context): \(msg)")
        }
    }

    private func recreateLocked() {
        sqlite3_close(connection)
        connection = nil
        if let url = databaseURL() {
            try? FileManager.default.removeItem(at: url)
        }
        openLocked()
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = connection else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            handle(sqlite3_errcode(db), context: "prepare")
            return false
        }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            handle(step, context: "step")
            return false
        }
        return true
    }

    // MARK: - Public API

    /// Appends a row. `flag` marks a row as claimed by an in-flight batch —
    /// it is never set before the server has acknowledged the send.
    @discardableResult
    func insert(_ type: PersistenceType, data: Data, flag: Bool = false) -> Bool {
        queue.sync {
            guard let db = connection else { return false }
            let sql = "INSERT INTO \(tableName(type)) (data, flag, time) VALUES(?, ?, ?);"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                handle(sqlite3_errcode(db), context: "insert prepare")
                return false
            }
            let ok = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                sqlite3_bind_blob(stmt, 1, base, Int32(raw.count), Self.transient)
                sqlite3_bind_int(stmt, 2, flag ? 1 : 0)
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
                let step = sqlite3_step(stmt)
                if step != SQLITE_DONE {
                    handle(step, context: "insert step")
                    return false
                }
                return true
            }
            return ok
        }
    }

    /// Oldest-first. Returns `(id, payload)` so the caller can delete exactly
    /// what it successfully sent — never a blanket delete.
    func read(_ type: PersistenceType, limit: Int, flag: Bool = false) -> [(id: Int32, data: Data)] {
        queue.sync {
            guard let db = connection, limit > 0 else { return [] }
            let sql = """
                SELECT id, data FROM \(tableName(type)) WHERE flag = \(flag ? 1 : 0)
                ORDER BY time LIMIT \(limit)
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                handle(sqlite3_errcode(db), context: "read prepare")
                return []
            }
            var rows: [(id: Int32, data: Data)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                autoreleasepool {
                    guard let blob = sqlite3_column_blob(stmt, 1) else { return }
                    let count = sqlite3_column_bytes(stmt, 1)
                    rows.append(
                        (id: sqlite3_column_int(stmt, 0), data: Data(bytes: blob, count: Int(count))))
                }
            }
            return rows
        }
    }

    /// Deletes exactly the supplied ids. An empty list is a no-op — upstream
    /// generates malformed SQL here, which cascades into wiping the database.
    @discardableResult
    func delete(_ type: PersistenceType, ids: [Int32]) -> Bool {
        guard !ids.isEmpty else { return true }
        return queue.sync {
            let list = ids.map(String.init).joined(separator: ",")
            return exec("DELETE FROM \(tableName(type)) WHERE id IN (\(list));")
        }
    }

    @discardableResult
    func deleteAll(_ type: PersistenceType) -> Bool {
        queue.sync { exec("DELETE FROM \(tableName(type));") }
    }

    /// Clears every claim flag. Called once at process start: a crash or a kill
    /// while a batch was in flight leaves those rows flagged, and a flagged row
    /// is invisible to `read(flag: false)` forever after. Upstream never
    /// releases them, so events stranded by one crash are never sent again.
    @discardableResult
    func releaseAllClaims(_ type: PersistenceType) -> Bool {
        queue.sync { exec("UPDATE \(tableName(type)) SET flag = 0 WHERE flag = 1;") }
    }

    @discardableResult
    func setFlag(_ type: PersistenceType, ids: [Int32], to newValue: Bool) -> Bool {
        guard !ids.isEmpty else { return true }
        return queue.sync {
            let list = ids.map(String.init).joined(separator: ",")
            return exec(
                "UPDATE \(tableName(type)) SET flag = \(newValue ? 1 : 0) WHERE id IN (\(list));")
        }
    }

    func count(_ type: PersistenceType) -> Int {
        queue.sync {
            guard let db = connection else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard
                sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(tableName(type));", -1, &stmt, nil)
                    == SQLITE_OK
            else { return 0 }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    /// Enforces the disk ceiling by evicting the oldest rows. Without this an
    /// offline device grows the queue without bound.
    @discardableResult
    func trim(_ type: PersistenceType, to maxRows: Int) -> Int {
        let excess = count(type) - maxRows
        guard excess > 0 else { return 0 }
        let ok = queue.sync {
            exec(
                """
                DELETE FROM \(tableName(type)) WHERE id IN (
                  SELECT id FROM \(tableName(type)) ORDER BY time ASC LIMIT \(excess)
                );
                """)
        }
        return ok ? excess : 0
    }

    /// Test seam.
    var isOpen: Bool { queue.sync { connection != nil } }
}

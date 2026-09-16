import Foundation
import SQLite3

/// Reads Cursor's `state.vscdb` through the SQLite C API. The database is
/// large and held open by a running Cursor, so it is opened read-only with the
/// `immutable=1` URI and never copied or written. Any failure yields `[]`.
enum CursorUsageReader {
    static func read(databasePath: String, calendar: Calendar) -> [CursorComposerUsage] {
        guard FileManager.default.isReadableFile(atPath: databasePath),
              let encoded = databasePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return [] }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file:\(encoded)?immutable=1", &handle, flags, nil) == SQLITE_OK, let db = handle
        else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var statement: OpaquePointer?
        let sql = """
        SELECT key, value FROM cursorDiskKV
        WHERE key LIKE 'composerData:%' AND value LIKE '%"costInCents"%'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let query = statement else { return [] }
        defer { sqlite3_finalize(query) }

        var rows: [CursorComposerUsage] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_text(query, 0) else { continue }
            let key = String(cString: keyPointer)
            let length = Int(sqlite3_column_bytes(query, 1))
            guard length > 0, let bytes = sqlite3_column_blob(query, 1) else { continue }
            let value = Data(bytes: bytes, count: length)
            rows.append(contentsOf: self.parse(composerKey: key, value: value, calendar: calendar))
        }
        return rows
    }

    /// Exposed for the checks: one composer value → one row per model.
    static func parse(composerKey: String, value: Data, calendar: Calendar) -> [CursorComposerUsage] {
        guard let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let usage = object["usageData"] as? [String: Any], !usage.isEmpty
        else { return [] }
        let createdMilliseconds = AgentUsageLines.int64(object["createdAt"])
        guard createdMilliseconds > 0 else { return [] }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdMilliseconds) / 1000)
        let updatedMilliseconds = AgentUsageLines.int64(object["lastUpdatedAt"])
        let updatedAt = updatedMilliseconds > 0
            ? Date(timeIntervalSince1970: TimeInterval(updatedMilliseconds) / 1000)
            : createdAt
        let date = AgentUsageDates.localDate(updatedAt, calendar: calendar)
        let hashed = AgentUsageHash.key(for: composerKey)
        return usage.compactMap { model, entry -> CursorComposerUsage? in
            guard let fields = entry as? [String: Any] else { return nil }
            let requests = AgentUsageLines.int(fields["amount"])
            let cents = AgentUsageLines.int(fields["costInCents"])
            guard requests > 0 || cents > 0 else { return nil }
            return CursorComposerUsage(
                composerKey: hashed,
                date: date,
                model: model.isEmpty ? "unknown" : model,
                requests: requests,
                costCents: cents,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
        .sorted { $0.model < $1.model }
    }
}

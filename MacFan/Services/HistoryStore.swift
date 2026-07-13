import Foundation
import SQLite3

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour
    case sixHours
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: "1H"
        case .sixHours: "6H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }

    /// Width of one chart bucket for this range. Also drives the gap threshold
    /// charts use to avoid drawing lines across missing periods (e.g. sleep).
    var displayBucketSeconds: Int {
        switch self {
        case .hour: 30
        case .sixHours: 120
        case .day: 300
        case .week: 3_600
        case .month: 7_200
        }
    }

    var gapThreshold: TimeInterval { TimeInterval(displayBucketSeconds * 3) }
}

/// Multi-resolution telemetry retention:
///   - `samples`: raw ticks (3–10 s cadence), kept 24 hours;
///   - `agg60`:   1-minute min/avg/max/last buckets, kept 7 days;
///   - `agg300`:  5-minute min/avg/max/last buckets, kept 30 days.
/// Raw rows older than 24 hours cascade into both tiers and are deleted, so the
/// database stays bounded while long ranges keep genuine peaks and troughs.
actor HistoryStore {
    private var database: OpaquePointer?
    private var lastRollup = Date.distantPast

    // Prepared statement cache to avoid repeated sqlite3_prepare_v2 + finalize
    // on the hot path (record + range queries). Big win for efficiency.
    private var statementCache: [String: OpaquePointer] = [:]

    init(fileURL: URL? = nil, inMemory: Bool = false) {
        let defaultURL = Self.defaultDatabaseURL()
        let url = fileURL ?? defaultURL
        do {
            if !inMemory {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            var openedDatabase: OpaquePointer?
            let databasePath = inMemory ? ":memory:" : url.path
            let result = sqlite3_open_v2(databasePath, &openedDatabase, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let openedDatabase else {
                self.database = nil
                return
            }
            self.database = openedDatabase
            Self.execute("PRAGMA journal_mode=WAL;", on: openedDatabase)
            Self.execute("PRAGMA synchronous=NORMAL;", on: openedDatabase)
            Self.execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    timestamp REAL PRIMARY KEY NOT NULL,
                    hottest REAL,
                    cpu REAL,
                    gpu REAL,
                    actual_rpm REAL,
                    requested_rpm REAL,
                    firmware_target_rpm REAL,
                    macfan_target_rpm REAL,
                    mode TEXT,
                    capability TEXT
                );
            """, on: openedDatabase)
            for tier in Self.tiers {
                Self.execute("""
                    CREATE TABLE IF NOT EXISTS \(tier.table) (
                        bucket REAL PRIMARY KEY NOT NULL,
                        sample_count INTEGER,
                        temp_min REAL,
                        temp_avg REAL,
                        temp_max REAL,
                        temp_last REAL,
                        cpu_min REAL,
                        cpu_avg REAL,
                        cpu_max REAL,
                        cpu_sample_count INTEGER,
                        gpu_avg REAL,
                        rpm_min REAL,
                        rpm_avg REAL,
                        rpm_max REAL,
                        rpm_last REAL,
                        rpm_sample_count INTEGER,
                        firmware_target_avg REAL,
                        firmware_target_sample_count INTEGER,
                        macfan_target_avg REAL,
                        macfan_target_sample_count INTEGER,
                        mode TEXT,
                        capability TEXT,
                        coverage_seconds REAL,
                        mode_system_seconds REAL,
                        mode_smart_boost_seconds REAL,
                        mode_max_seconds REAL,
                        mode_expert_seconds REAL,
                        band_muted_seconds REAL,
                        band_cool_seconds REAL,
                        band_indigo_seconds REAL,
                        band_violet_seconds REAL,
                        band_amber_seconds REAL,
                        band_hot_seconds REAL
                    );
                """, on: openedDatabase)
            }
            // Keep existing local history readable after a schema update. The
            // legacy requested columns contain firmware telemetry, never an app command.
            for column in [
                SchemaColumn(name: "hottest", definition: "REAL"),
                SchemaColumn(name: "cpu", definition: "REAL"),
                SchemaColumn(name: "gpu", definition: "REAL"),
                SchemaColumn(name: "actual_rpm", definition: "REAL"),
                SchemaColumn(name: "requested_rpm", definition: "REAL"),
                SchemaColumn(name: "firmware_target_rpm", definition: "REAL"),
                SchemaColumn(name: "macfan_target_rpm", definition: "REAL"),
                SchemaColumn(name: "mode", definition: "TEXT"),
                SchemaColumn(name: "capability", definition: "TEXT")
            ] {
                Self.ensureColumn(column.name, definition: column.definition, in: "samples", on: openedDatabase)
            }
            for tier in Self.tiers {
                for column in Self.tierColumns {
                    Self.ensureColumn(column.name, definition: column.definition, in: tier.table, on: openedDatabase)
                }
            }
            Self.execute("CREATE INDEX IF NOT EXISTS samples_timestamp_idx ON samples(timestamp);", on: openedDatabase)
            Self.migrateLegacyHourly(on: openedDatabase)
            // Older aggregate tiers only carried CPU averages. They remain
            // readable after migration; unknown historical extrema fall back
            // to that average instead of being fabricated from hottest-die data.
            for tier in Self.tiers {
                Self.execute("UPDATE \(tier.table) SET cpu_min = cpu_avg WHERE cpu_min IS NULL AND cpu_avg IS NOT NULL;", on: openedDatabase)
                Self.execute("UPDATE \(tier.table) SET cpu_max = cpu_avg WHERE cpu_max IS NULL AND cpu_avg IS NOT NULL;", on: openedDatabase)
                Self.execute("UPDATE \(tier.table) SET cpu_sample_count = sample_count WHERE cpu_sample_count IS NULL AND cpu_avg IS NOT NULL;", on: openedDatabase)
                // Pre-count schemas stored only averages. Preserve their best
                // available weighting by treating a present metric as observed
                // for the row's recorded sample count; a missing nullable
                // target contributes zero observations rather than diluting a
                // later non-null target average.
                Self.execute("UPDATE \(tier.table) SET rpm_sample_count = CASE WHEN rpm_avg IS NULL THEN 0 ELSE COALESCE(sample_count, 1) END WHERE rpm_sample_count IS NULL;", on: openedDatabase)
                Self.execute("UPDATE \(tier.table) SET firmware_target_sample_count = CASE WHEN firmware_target_avg IS NULL THEN 0 ELSE COALESCE(sample_count, 1) END WHERE firmware_target_sample_count IS NULL;", on: openedDatabase)
                Self.execute("UPDATE \(tier.table) SET macfan_target_sample_count = CASE WHEN macfan_target_avg IS NULL THEN 0 ELSE COALESCE(sample_count, 1) END WHERE macfan_target_sample_count IS NULL;", on: openedDatabase)
            }
        } catch {
            self.database = nil
        }
    }

    deinit {
        // Actor deinitializers already have exclusive access to stored state;
        // finalize inline so this remains valid under Swift 6 isolation rules.
        for statement in statementCache.values {
            sqlite3_finalize(statement)
        }
        if let database { sqlite3_close(database) }
    }

    func record(_ sample: TelemetrySample) {
        guard database != nil else { return }
        let sql = """
            INSERT OR REPLACE INTO samples
            (timestamp, hottest, cpu, gpu, actual_rpm, requested_rpm, firmware_target_rpm, macfan_target_rpm, mode, capability)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let statement = getOrPrepareStatement(sql) else { return }
        sqlite3_reset(statement)

        sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
        bind(sample.hottestCelsius, statement, at: 2)
        bind(sample.cpuCelsius, statement, at: 3)
        bind(sample.gpuCelsius, statement, at: 4)
        bind(sample.averageActualRPM, statement, at: 5)
        // `requested_rpm` is retained only for compatibility with existing local databases.
        bind(sample.averageFirmwareTargetRPM, statement, at: 6)
        bind(sample.averageFirmwareTargetRPM, statement, at: 7)
        bind(sample.averageMacFanTargetRPM, statement, at: 8)
        sample.mode.rawValue.withCString { mode in
            sample.capability.rawValue.withCString { capability in
                sqlite3_bind_text(statement, 9, mode, -1, nil)
                sqlite3_bind_text(statement, 10, capability, -1, nil)
                _ = sqlite3_step(statement)
            }
        }

        if sample.timestamp.timeIntervalSince(lastRollup) >= 60,
           pruneAndRollup(now: sample.timestamp) {
            lastRollup = sample.timestamp
        }
    }

    func samples(for range: HistoryRange, now: Date = .now) -> [TelemetrySample] {
        guard database != nil else { return [] }
        let lowerBound = now.addingTimeInterval(-range.interval).timeIntervalSince1970
        let bucket = range.displayBucketSeconds
        let rawSQL = rawQuery(bucket: bucket)
        let tierTable: String? = switch range {
        case .hour, .sixHours, .day: nil
        case .week: "agg60"
        case .month: "agg300"
        }
        let sql: String
        if let tierTable {
            sql = """
                \(tierQuery(table: tierTable, displayBucket: bucket))
                UNION ALL
                \(rawSQL)
                ORDER BY timestamp ASC;
            """
        } else {
            sql = rawSQL + " ORDER BY timestamp ASC;"
        }

        guard let statement = getOrPrepareStatement(sql) else { return [] }
        sqlite3_reset(statement) // safe reuse
        sqlite3_bind_double(statement, 1, lowerBound)
        if tierTable != nil { sqlite3_bind_double(statement, 2, lowerBound) }

        return decodeSamples(from: statement)
    }

    /// Returns exactly the most recent 90 minutes, bucketed into approximately
    /// sixty timestamped bars for the compact popover.
    func thermalTrail(now: Date = .now) -> [TelemetrySample] {
        guard database != nil else { return [] }
        let lowerBound = now.addingTimeInterval(-90 * 60).timeIntervalSince1970
        let sql = rawQuery(bucket: 90) + " ORDER BY timestamp ASC;"
        guard let statement = getOrPrepareStatement(sql) else { return [] }
        sqlite3_reset(statement)
        sqlite3_bind_double(statement, 1, lowerBound)
        return decodeSamples(from: statement)
    }

    func purgeAll() {
        execute("DELETE FROM samples;")
        for tier in Self.tiers { execute("DELETE FROM \(tier.table);") }
    }

    func close() {
        finalizeAllCachedStatements()
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    private static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacFan", isDirectory: true).appendingPathComponent("telemetry.sqlite")
    }

    private func bind(_ value: Double?, _ statement: OpaquePointer, at index: Int32) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func value(_ statement: OpaquePointer, at index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    // MARK: - Prepared statement cache & deferred rollup helpers

    private func getOrPrepareStatement(_ sql: String) -> OpaquePointer? {
        if let cached = statementCache[sql] {
            return cached
        }
        var stmt: OpaquePointer?
        guard let db = database,
              sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            return nil
        }
        statementCache[sql] = statement
        return statement
    }

    private func finalizeAllCachedStatements() {
        for (_, stmt) in statementCache {
            sqlite3_finalize(stmt)
        }
        statementCache.removeAll()
    }

    private struct Tier {
        let table: String
        let seconds: Int
        let retention: TimeInterval
    }

    private struct SchemaColumn {
        let name: String
        let definition: String
    }

    /// Columns are checked individually because `CREATE TABLE IF NOT EXISTS`
    /// does not evolve an installation's existing aggregate tables.
    private static let tierColumns: [SchemaColumn] = [
        .init(name: "sample_count", definition: "INTEGER"),
        .init(name: "temp_min", definition: "REAL"),
        .init(name: "temp_avg", definition: "REAL"),
        .init(name: "temp_max", definition: "REAL"),
        .init(name: "temp_last", definition: "REAL"),
        .init(name: "cpu_min", definition: "REAL"),
        .init(name: "cpu_avg", definition: "REAL"),
        .init(name: "cpu_max", definition: "REAL"),
        .init(name: "cpu_sample_count", definition: "INTEGER"),
        .init(name: "gpu_avg", definition: "REAL"),
        .init(name: "rpm_min", definition: "REAL"),
        .init(name: "rpm_avg", definition: "REAL"),
        .init(name: "rpm_max", definition: "REAL"),
        .init(name: "rpm_last", definition: "REAL"),
        .init(name: "rpm_sample_count", definition: "INTEGER"),
        .init(name: "firmware_target_avg", definition: "REAL"),
        .init(name: "firmware_target_sample_count", definition: "INTEGER"),
        .init(name: "macfan_target_avg", definition: "REAL"),
        .init(name: "macfan_target_sample_count", definition: "INTEGER"),
        .init(name: "mode", definition: "TEXT"),
        .init(name: "capability", definition: "TEXT"),
        .init(name: "coverage_seconds", definition: "REAL"),
        .init(name: "mode_system_seconds", definition: "REAL"),
        .init(name: "mode_smart_boost_seconds", definition: "REAL"),
        .init(name: "mode_max_seconds", definition: "REAL"),
        .init(name: "mode_expert_seconds", definition: "REAL"),
        .init(name: "band_muted_seconds", definition: "REAL"),
        .init(name: "band_cool_seconds", definition: "REAL"),
        .init(name: "band_indigo_seconds", definition: "REAL"),
        .init(name: "band_violet_seconds", definition: "REAL"),
        .init(name: "band_amber_seconds", definition: "REAL"),
        .init(name: "band_hot_seconds", definition: "REAL")
    ]

    /// A recorded sample is allowed to represent at most the app's forced
    /// history-write cadence. Longer intervals are telemetry gaps (usually
    /// sleep) and must not inflate duration insights.
    static let maximumCoveredInterval: TimeInterval = 30

    private static let tiers = [
        Tier(table: "agg60", seconds: 60, retention: HistoryRange.week.interval),
        Tier(table: "agg300", seconds: 300, retention: HistoryRange.month.interval)
    ]

    /// Compaction is all-or-nothing: raw observations are deleted only after
    /// every aggregate tier and retention prune has succeeded. This prevents a
    /// transient SQLite error from turning a recoverable rollup into lost
    /// history.
    @discardableResult
    private func pruneAndRollup(now: Date) -> Bool {
        guard let database else { return false }
        let rawCutoff = now.addingTimeInterval(-HistoryRange.day.interval).timeIntervalSince1970
        // Only compact fully completed buckets. 300 is the least common multiple
        // of both tier widths, so aligning the cutoff to it guarantees no bucket
        // is ever rolled from a partial set of its samples and later replaced
        // using only the remainder, which would silently lose history.
        let completedCutoff = floor(rawCutoff / 300) * 300
        guard Self.executeChecked("BEGIN IMMEDIATE;", on: database) else { return false }

        var succeeded = true
        for tier in Self.tiers where succeeded {
            succeeded = Self.executeChecked(
                rollupSQL(tier: tier, cutoff: completedCutoff),
                on: database
            )
        }

        if succeeded {
            succeeded = Self.executeChecked(
                "DELETE FROM samples WHERE timestamp < \(completedCutoff);",
                on: database
            )
        }
        for tier in Self.tiers where succeeded {
            let tierCutoff = now.addingTimeInterval(-tier.retention).timeIntervalSince1970
            succeeded = Self.executeChecked(
                "DELETE FROM \(tier.table) WHERE bucket < \(tierCutoff);",
                on: database
            )
        }

        if succeeded, Self.executeChecked("COMMIT;", on: database) {
            return true
        }
        Self.execute("ROLLBACK;", on: database)
        return false
    }

    private func rollupSQL(tier: Tier, cutoff: Double) -> String {
        let width = tier.seconds
        // The correlated subqueries pick the newest row of each bucket so the
        // aggregate keeps a true "latest" value alongside min/avg/max.
        return """
            INSERT OR REPLACE INTO \(tier.table) (
                   bucket, sample_count,
                   temp_min, temp_avg, temp_max, temp_last,
                   cpu_min, cpu_avg, cpu_max, cpu_sample_count, gpu_avg,
                   rpm_min, rpm_avg, rpm_max, rpm_last, rpm_sample_count,
                   firmware_target_avg, firmware_target_sample_count,
                   macfan_target_avg, macfan_target_sample_count,
                   mode, capability,
                   coverage_seconds,
                   mode_system_seconds, mode_smart_boost_seconds, mode_max_seconds, mode_expert_seconds,
                   band_muted_seconds, band_cool_seconds, band_indigo_seconds,
                   band_violet_seconds, band_amber_seconds, band_hot_seconds
            )
            SELECT CAST(observed.timestamp / \(width) AS INTEGER) * \(width),
                   COUNT(*),
                   MIN(observed.hottest), AVG(observed.hottest), MAX(observed.hottest),
                   (SELECT s2.hottest FROM samples s2
                     WHERE s2.timestamp < \(cutoff)
                       AND CAST(s2.timestamp / \(width) AS INTEGER) = CAST(observed.timestamp / \(width) AS INTEGER)
                     ORDER BY s2.timestamp DESC LIMIT 1),
                   MIN(observed.cpu), AVG(observed.cpu), MAX(observed.cpu), COUNT(observed.cpu),
                   AVG(observed.gpu),
                   MIN(observed.actual_rpm), AVG(observed.actual_rpm), MAX(observed.actual_rpm),
                   (SELECT s3.actual_rpm FROM samples s3
                     WHERE s3.timestamp < \(cutoff)
                       AND CAST(s3.timestamp / \(width) AS INTEGER) = CAST(observed.timestamp / \(width) AS INTEGER)
                     ORDER BY s3.timestamp DESC LIMIT 1),
                   COUNT(observed.actual_rpm),
                   AVG(COALESCE(observed.firmware_target_rpm, observed.requested_rpm)),
                   COUNT(COALESCE(observed.firmware_target_rpm, observed.requested_rpm)),
                   AVG(observed.macfan_target_rpm),
                   COUNT(observed.macfan_target_rpm),
                   (SELECT latest.mode FROM samples latest
                     WHERE latest.timestamp < \(cutoff)
                       AND CAST(latest.timestamp / \(width) AS INTEGER) = CAST(observed.timestamp / \(width) AS INTEGER)
                     ORDER BY latest.timestamp DESC LIMIT 1),
                   (SELECT latest.capability FROM samples latest
                     WHERE latest.timestamp < \(cutoff)
                       AND CAST(latest.timestamp / \(width) AS INTEGER) = CAST(observed.timestamp / \(width) AS INTEGER)
                     ORDER BY latest.timestamp DESC LIMIT 1),
                   \(Self.durationAggregateSQL)
              FROM \(Self.observedSamplesSQL) AS observed
             WHERE observed.timestamp < \(cutoff)
             GROUP BY CAST(observed.timestamp / \(width) AS INTEGER);
        """
    }

    private func execute(_ sql: String) {
        Self.execute(sql, on: database)
    }

    /// Adds a bounded observed duration to each raw row. The next timestamp is
    /// found through the indexed primary key, avoiding a window over the full
    /// raw table for every short-range query. A missing successor contributes
    /// zero; a distant successor contributes at most 30 seconds.
    private static var observedSamplesSQL: String {
        """
        (
            SELECT sequenced.*,
                   CASE WHEN sequenced.next_timestamp > sequenced.timestamp
                        THEN MIN(\(maximumCoveredInterval), sequenced.next_timestamp - sequenced.timestamp)
                        ELSE 0 END AS coverage_seconds
              FROM (
                    SELECT source.*,
                           (SELECT MIN(successor.timestamp)
                              FROM samples successor
                             WHERE successor.timestamp > source.timestamp) AS next_timestamp
                      FROM samples source
                   ) AS sequenced
        )
        """
    }

    /// Duration columns deliberately use CPU temperature first, matching the
    /// product's headline metric, and fall back to hottest-sensor telemetry only
    /// when CPU telemetry is absent. Thresholds come exclusively from
    /// `ThermalPalette`.
    private static var durationAggregateSQL: String {
        let temperature = "COALESCE(observed.cpu, observed.hottest)"
        return """
        SUM(observed.coverage_seconds),
        SUM(CASE WHEN COALESCE(observed.mode, 'system') = 'system' THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN observed.mode = 'smartBoost' THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN observed.mode = 'max' THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN observed.mode = 'expert' THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN \(temperature) IS NULL THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN \(temperature) < \(ThermalPalette.indigoMinimum) THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN \(temperature) >= \(ThermalPalette.indigoMinimum) AND \(temperature) < \(ThermalPalette.violetMinimum) THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN \(temperature) >= \(ThermalPalette.violetMinimum) AND \(temperature) < \(ThermalPalette.amberMinimum) THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN \(temperature) >= \(ThermalPalette.amberMinimum) AND \(temperature) < \(ThermalPalette.hotMinimum) THEN observed.coverage_seconds ELSE 0 END),
        SUM(CASE WHEN \(temperature) >= \(ThermalPalette.hotMinimum) THEN observed.coverage_seconds ELSE 0 END)
        """
    }

    /// All range queries produce the same 26-column layout consumed by
    /// `decodeSamples`: hottest and CPU extrema, averages, RPM extrema, latest
    /// state, then additive coverage/mode/thermal-band durations.
    private func rawQuery(bucket: Int) -> String {
        """
            SELECT CAST(observed.timestamp / \(bucket) AS INTEGER) * \(bucket) AS timestamp,
                   MIN(observed.hottest), AVG(observed.hottest), MAX(observed.hottest),
                   MIN(observed.cpu), AVG(observed.cpu), MAX(observed.cpu), AVG(observed.gpu),
                   MIN(observed.actual_rpm), AVG(observed.actual_rpm), MAX(observed.actual_rpm),
                   AVG(COALESCE(observed.firmware_target_rpm, observed.requested_rpm)),
                   AVG(observed.macfan_target_rpm),
                   (SELECT latest.mode FROM samples latest
                     WHERE CAST(latest.timestamp / \(bucket) AS INTEGER) = CAST(observed.timestamp / \(bucket) AS INTEGER)
                     ORDER BY latest.timestamp DESC LIMIT 1),
                   (SELECT latest.capability FROM samples latest
                     WHERE CAST(latest.timestamp / \(bucket) AS INTEGER) = CAST(observed.timestamp / \(bucket) AS INTEGER)
                     ORDER BY latest.timestamp DESC LIMIT 1),
                   \(Self.durationAggregateSQL)
              FROM \(Self.observedSamplesSQL) AS observed
             WHERE observed.timestamp >= ?
             GROUP BY CAST(observed.timestamp / \(bucket) AS INTEGER)
        """
    }

    private func tierQuery(table: String, displayBucket: Int) -> String {
        """
            SELECT CAST(bucket / \(displayBucket) AS INTEGER) * \(displayBucket) AS timestamp,
                   MIN(temp_min), AVG(temp_avg), MAX(temp_max),
                   MIN(COALESCE(cpu_min, cpu_avg)),
                   COALESCE(
                       SUM(cpu_avg * cpu_sample_count) / NULLIF(SUM(cpu_sample_count), 0),
                       AVG(cpu_avg)
                   ),
                   MAX(COALESCE(cpu_max, cpu_avg)), AVG(gpu_avg),
                   MIN(rpm_min),
                   COALESCE(
                       SUM(rpm_avg * rpm_sample_count) / NULLIF(SUM(rpm_sample_count), 0),
                       AVG(rpm_avg)
                   ),
                   MAX(rpm_max),
                   COALESCE(
                       SUM(firmware_target_avg * firmware_target_sample_count)
                           / NULLIF(SUM(firmware_target_sample_count), 0),
                       AVG(firmware_target_avg)
                   ),
                   COALESCE(
                       SUM(macfan_target_avg * macfan_target_sample_count)
                           / NULLIF(SUM(macfan_target_sample_count), 0),
                       AVG(macfan_target_avg)
                   ),
                   (SELECT latest.mode FROM \(table) latest
                     WHERE CAST(latest.bucket / \(displayBucket) AS INTEGER) = CAST(\(table).bucket / \(displayBucket) AS INTEGER)
                     ORDER BY latest.bucket DESC LIMIT 1),
                   (SELECT latest.capability FROM \(table) latest
                     WHERE CAST(latest.bucket / \(displayBucket) AS INTEGER) = CAST(\(table).bucket / \(displayBucket) AS INTEGER)
                     ORDER BY latest.bucket DESC LIMIT 1),
                   SUM(coverage_seconds),
                   SUM(mode_system_seconds), SUM(mode_smart_boost_seconds),
                   SUM(mode_max_seconds), SUM(mode_expert_seconds),
                   SUM(band_muted_seconds), SUM(band_cool_seconds), SUM(band_indigo_seconds),
                   SUM(band_violet_seconds), SUM(band_amber_seconds), SUM(band_hot_seconds)
              FROM \(table)
             WHERE bucket >= ?
             GROUP BY CAST(bucket / \(displayBucket) AS INTEGER)
        """
    }

    private func decodeSamples(from statement: OpaquePointer) -> [TelemetrySample] {
        var result: [TelemetrySample] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            result.append(
                TelemetrySample(
                    timestamp: timestamp,
                    hottestCelsius: value(statement, at: 2),
                    cpuCelsius: value(statement, at: 5),
                    gpuCelsius: value(statement, at: 7),
                    averageActualRPM: value(statement, at: 9),
                    averageFirmwareTargetRPM: value(statement, at: 11),
                    minCelsius: value(statement, at: 1),
                    maxCelsius: value(statement, at: 3),
                    minCPUCelsius: value(statement, at: 4),
                    maxCPUCelsius: value(statement, at: 6),
                    minRPM: value(statement, at: 8),
                    maxRPM: value(statement, at: 10),
                    recordedCoverageSeconds: value(statement, at: 15),
                    modeDurations: durationMap(
                        statement,
                        keys: FanMode.allCases,
                        startingAt: 16
                    ),
                    thermalBandDurations: durationMap(
                        statement,
                        keys: ThermalBand.allCases,
                        startingAt: 20
                    ),
                    averageMacFanTargetRPM: value(statement, at: 12),
                    mode: FanMode(rawValue: text(statement, at: 13) ?? "") ?? .system,
                    capability: ControlCapability(rawValue: text(statement, at: 14) ?? "") ?? .monitoring
                )
            )
        }
        return result
    }

    private func durationMap<Key: Hashable>(
        _ statement: OpaquePointer,
        keys: [Key],
        startingAt firstColumn: Int32
    ) -> [Key: TimeInterval]? {
        var durations: [Key: TimeInterval] = [:]
        var observedAValue = false
        for (offset, key) in keys.enumerated() {
            let column = firstColumn + Int32(offset)
            if let duration = value(statement, at: column) {
                durations[key] = duration
                observedAValue = true
            }
        }
        return observedAValue ? durations : nil
    }

    private func text(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    /// Copies the pre-tier `hourly` rollup table into both aggregate tiers so
    /// existing 30-day history stays visible, then drops it. The legacy schema
    /// only stored averages and a peak, so min falls back to the average.
    private static func migrateLegacyHourly(on database: OpaquePointer) {
        guard tableExists("hourly", on: database) else { return }
        for column in [
            ("average_cpu", "REAL"), ("average_gpu", "REAL"), ("peak_temp", "REAL"),
            ("average_requested_rpm", "REAL"), ("average_firmware_target_rpm", "REAL"),
            ("average_macfan_target_rpm", "REAL"), ("mode", "TEXT"), ("capability", "TEXT")
        ] {
            ensureColumn(column.0, definition: column.1, in: "hourly", on: database)
        }
        var migrated = true
        for table in ["agg60", "agg300"] {
            let copied = executeChecked("""
                INSERT OR IGNORE INTO \(table) (
                       bucket, sample_count,
                       temp_min, temp_avg, temp_max, temp_last,
                       cpu_min, cpu_avg, cpu_max, cpu_sample_count, gpu_avg,
                       rpm_min, rpm_avg, rpm_max, rpm_last, rpm_sample_count,
                       firmware_target_avg, firmware_target_sample_count,
                       macfan_target_avg, macfan_target_sample_count,
                       mode, capability,
                       coverage_seconds,
                       mode_system_seconds, mode_smart_boost_seconds, mode_max_seconds, mode_expert_seconds,
                       band_muted_seconds, band_cool_seconds, band_indigo_seconds,
                       band_violet_seconds, band_amber_seconds, band_hot_seconds
                )
                SELECT bucket, 1,
                       average_temp, average_temp, COALESCE(peak_temp, average_temp), average_temp,
                       COALESCE(average_cpu, average_temp), COALESCE(average_cpu, average_temp),
                       COALESCE(average_cpu, average_temp), 1, average_gpu,
                       average_actual_rpm, average_actual_rpm, average_actual_rpm, average_actual_rpm,
                       CASE WHEN average_actual_rpm IS NULL THEN 0 ELSE 1 END,
                       COALESCE(average_firmware_target_rpm, average_requested_rpm),
                       CASE WHEN COALESCE(average_firmware_target_rpm, average_requested_rpm) IS NULL THEN 0 ELSE 1 END,
                       average_macfan_target_rpm,
                       CASE WHEN average_macfan_target_rpm IS NULL THEN 0 ELSE 1 END,
                       mode, capability,
                       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
                  FROM hourly;
            """, on: database)
            migrated = migrated && copied
        }
        // Never drop the legacy data unless both copies definitely succeeded.
        if migrated {
            execute("DROP TABLE hourly;", on: database)
        }
    }

    private static func tableExists(_ table: String, on database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func ensureColumn(_ column: String, definition: String, in table: String, on database: OpaquePointer) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: rawName) == column { return }
        }
        execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);", on: database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer?) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    @discardableResult
    private static func executeChecked(_ sql: String, on database: OpaquePointer) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }
}

import CoreServices
import Darwin
import Foundation
import os

public final class StorageBroker {
    private let support: URL
    private var index: IndexWriter!
    private let requestedAccess: DiskAccess
    private let access: DiskAccess
    private var nextAccessCheck = ContinuousClock.now + .seconds(5)
    private let lockFD: Int32
    private let worker = DispatchQueue(label: "io.spacetrail.index", qos: .utility)
    private let logger = Logger(subsystem: "io.spacetrail.broker", category: "index")
    private let trees: [VolumeTree]
    private var scanner: FileScanner!
    private var events: FileEvents!
    private var eventSignal: DispatchSourceUserDataAdd?
    private var maintenanceTimer: DispatchSourceTimer?
    private var cacheReleaseTimer: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var parentWatcher: DispatchSourceProcess?
    private var observers: [NSObjectProtocol] = []
    private var repairScheduled = false
    private var footprintScheduled = false
    private var footprintsComplete = false
    private var footprintRevisionPending = false
    private var lastFootprintRevision = ContinuousClock.now
    private var footprintTurn = 0
    private var phase: BrokerState.Phase = .preparing
    private var scanTotal: Int64 = 0
    private var scanStarted: Double = 0
    private var scanStartCount: Int64 = 0
    private var lastManualCheck = -Double.infinity
    private let parentPID: Int32?
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    public init(access: DiskAccess, support: URL = SpaceTrailPaths.support, parentPID: Int32? = nil) throws {
        self.support = support
        self.requestedAccess = access
        self.access = access.effective
        self.parentPID = parentPID
        self.trees = SpaceTrailPaths.fixtureRoot == nil ? [.data, .system] : [.data]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockPath = support.appendingPathComponent("writer.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FilesystemFailure(path: lockPath, code: errno) }
        var locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        if !locked, errno == EWOULDBLOCK, parentPID == nil,
           BrokerState.read(in: support)?.background == false {
            // The approved agent has actually launched. Let it take over from the
            // foreground helper without starting a second SQLite writer.
            DistributedNotificationCenter.default().postNotificationName(
                SpaceTrailPaths.backgroundTakeoverNotification, object: support.path,
                userInfo: nil, deliverImmediately: true
            )
            for _ in 0..<15 {
                usleep(100_000)
                locked = flock(fd, LOCK_EX | LOCK_NB) == 0
                if locked || errno != EWOULDBLOCK { break }
            }
        }
        guard locked else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw BrokerAlreadyRunning() }
            throw FilesystemFailure(path: lockPath, code: code)
        }
        lockFD = fd
    }

    deinit {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        close(lockFD)
    }

    public func start() {
        if let parentPID {
            guard getppid() == parentPID else { exit(EXIT_SUCCESS) }
            let source = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
            source.setEventHandler { exit(EXIT_SUCCESS) }
            source.activate()
            parentWatcher = source
            guard getppid() == parentPID else { exit(EXIT_SUCCESS) }
        }

        let signal = DispatchSource.makeUserDataAddSource(queue: worker)
        signal.setEventHandler { [weak self] in self?.applyEvents() }
        signal.activate()
        eventSignal = signal

        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: SpaceTrailPaths.reviewNotification, object: support.path, queue: nil) {
            [weak self] _ in
            self?.worker.async { [weak self] in self?.maintenance(manual: true) }
        })
        observers.append(center.addObserver(forName: SpaceTrailPaths.accessNotification, object: support.path, queue: nil) {
            _ in exit(EXIT_SUCCESS)
        })
        if parentPID != nil {
            observers.append(center.addObserver(forName: SpaceTrailPaths.backgroundTakeoverNotification, object: support.path, queue: nil) {
                _ in exit(EXIT_SUCCESS)
            })
        }

        worker.async { [weak self] in
            guard let self else { return }
            do {
                try self.bootstrap(signal: signal)
            }
            catch { self.fail(error) }
        }
    }

    private func bootstrap(signal: DispatchSourceUserDataAdd) throws {
        publish(.preparing)
        do {
            try IndexMigration.removeInterruptedCopy(in: support)
            try IndexMigration.migrateIfEligible(in: support) { publish(.compacting) }
        } catch {
            logger.notice("Compattazione rimandata: \(error.localizedDescription, privacy: .private)")
        }
        index = try IndexWriter(support: support)
        monitorMemoryPressure()
        publish(.preparing)
        let root = VolumeTree.data.root
        if let previous = try index.metadata("root"), previous != root {
            throw FilesystemFailure(path: root, code: EINVAL)
        }
        var devices: [VolumeTree: dev_t] = [:]
        for tree in trees { devices[tree] = try diskStat(tree.root).st_dev }
        guard let device = devices[.data] else { throw FilesystemFailure(path: root, code: ENODEV) }
        let mount = try mountInfo(root).mount
        let journalID = FileEvents.journalID(device: device)
        let saved = try index.metadata("event").flatMap(UInt64.init)
        let hasBaseline = try index.metadata("baseline") == "1"
        let sameJournal = try journalID != nil && index.metadata("journal") == journalID
        let watermark = FileEvents.currentCheckpoint()
        let canReplay = hasBaseline && sameJournal && saved.map { $0 > 0 } == true
        let fallback = (journalID == nil || watermark == 0) ? UInt64.max : watermark
        let initialWatermark = try index.metadata("initialWatermark").flatMap(UInt64.init)
        let initialJournal = try index.metadata("initialJournal")
        let initialRoot = try index.metadata("initialRoot")
        let sameInitialSetup = try index.metadata("initialTopology") == StartupVolumeLayout.version
        let canResume = !hasBaseline && (initialWatermark ?? 0) > 0
            && journalID != nil && initialJournal == journalID && initialRoot == root && sameInitialSetup
        let since = canReplay ? (saved ?? fallback) : (canResume ? (initialWatermark ?? fallback) : fallback)

        scanner = FileScanner(index: index, support: support, devices: devices, access: access) { [weak self] count in
            guard let self, self.phase == .scanning || self.phase == .recovering else { return }
            self.publish(self.phase, processed: count)
        }
        events = FileEvents(root: root, mount: mount, support: support.path) { signal.add(data: 1) }
        try events.start(device: device, since: since)

        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let savedSystem = try index.metadata("system")
        let systemChanged = trees.contains(.system) && savedSystem != systemVersion
        if !hasBaseline {
            if !canResume {
                try index.prepareInitialScan()
                try index.db.transaction("BEGIN IMMEDIATE") {
                    for tree in trees { try index.queueInitial(EntryKey(tree: tree, path: tree.root)) }
                    try index.set("initialWatermark", String(watermark))
                    try index.set("initialJournal", journalID ?? "")
                    try index.set("initialRoot", root)
                    try index.set("initialTopology", StartupVolumeLayout.version)
                    try index.set("initialCount", "0")
                }
            }
            if SpaceTrailPaths.fixtureRoot == nil {
                for tree in trees { scanTotal += try mountInfo(tree.root).entries }
            }
            let checkpoint = try index.metadata("initialCount").flatMap(Int64.init) ?? 0
            scanStarted = ProcessInfo.processInfo.systemUptime
            scanStartCount = checkpoint
            publish(.scanning, processed: checkpoint)
            try scanner.buildInitial(from: checkpoint)
            publish(.finishing, processed: scanner.processed)
            try index.db.transaction("BEGIN IMMEDIATE") {
                try index.set("event", String(canResume ? (initialWatermark ?? watermark) : watermark))
                try index.set("journal", journalID ?? "")
                try index.set("baselineAt", String(Date().timeIntervalSince1970))
                if trees.contains(.system) { try index.set("system", systemVersion) }
                try index.set("root", root)
                try index.set("baseline", "1")
                try index.set("searchComplete", "1")
                try index.set("topology", StartupVolumeLayout.version)
                try index.set("access", access.rawValue)
                try index.set("appData", access.scansAppData ? "1" : "0")
                try saveRevision(sample: true)
            }
            try index.db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        } else {
            if try index.metadata("searchComplete") != "1" {
                publish(.finishing)
                try index.prepareSearch(existingBaseline: true)
            }
            let topologyChanged = try index.metadata("topology") != StartupVolumeLayout.version
            if topologyChanged {
                publish(.recovering)
                try index.migrateSystemAliases(scheduleSystemRepair: trees.contains(.system))
            }
            let accessChanged = try index.metadata("access") != access.rawValue
            let appDataWasEnabled = try index.metadata("appData") == "1"
            let appDataEnabled = access.scansAppData && !appDataWasEnabled
            try index.db.transaction("BEGIN IMMEDIATE") {
                if !canReplay {
                    try index.scheduleRepair(EntryKey(tree: .data, path: root))
                    try index.set("event", String(watermark))
                    try index.set("journal", journalID ?? "")
                    try index.set("auditPath", "")
                }
                if systemChanged {
                    try index.scheduleRepair(EntryKey(tree: .system, path: "/"))
                    try index.set("system", systemVersion)
                }
                if access == .complete && (accessChanged || appDataEnabled) {
                    try index.scheduleLimitedScopes()
                    for key in try index.gaps(limit: 1_024, dueBefore: .distantFuture) {
                        try index.scheduleRepair(key)
                    }
                }
                try index.set("access", access.rawValue)
                try index.set("appData", access.scansAppData ? "1" : "0")
                try index.set("topology", StartupVolumeLayout.version)
                try saveRevision(sample: true, touchedFiles: topologyChanged)
            }
        }
        scanTotal = 0
        try apply(events.drain())
        try scheduleRepairs()
        try index.db.transaction("BEGIN IMMEDIATE") {
            if try index.metadata("footprintSeeded") != "1" {
                let ranking = try FolderRanking.load(from: index.db)
                try index.footprints.prioritize(ranking.filter { access.includes($0.id) })
                try index.set("footprintSeeded", "1")
            }
        }
        scheduleFootprints()

        let timer = DispatchSource.makeTimerSource(queue: worker)
        let interval = DispatchTimeInterval.seconds(20 * 60)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(90))
        timer.setEventHandler { [weak self] in self?.maintenance(manual: false) }
        timer.activate()
        maintenanceTimer = timer
    }

    private func applyEvents() {
        guard let events else { return }
        do { try apply(events.drain()) }
        catch { fail(error) }
    }

    private func apply(_ batch: EventBatch) throws {
        guard !batch.paths.isEmpty else { return }
        restartIfAccessChanged()
        let root = VolumeTree.data.root
        try index.db.transaction("BEGIN IMMEDIATE") {
            var changed = false
            if batch.dropped {
                try index.scheduleRepair(EntryKey(tree: .data, path: root))
            } else {
                var processed = 0
                try batch.forEachScope { path, scope in
                    let key = EntryKey(tree: .data, path: path)
                    if try scanner.refresh(key, recursive: scope.contains(.recursive),
                                           refreshAllocation: scope.contains(.allocation)) { changed = true }
                    processed += 1
                    if processed.isMultiple(of: 4_096) { try index.finishBatch() }
                }
            }
            // A saved event is either applied or durably represented by a pending scope.
            if let id = batch.checkpoint ?? (batch.wrapped ? FileEvents.currentCheckpoint() : nil) {
                let last = try index.metadata("event").flatMap(UInt64.init) ?? 0
                try index.set("event", String(batch.wrapped ? id : max(id, last)))
            }
            if batch.wrapped {
                let device = try diskStat(root).st_dev
                try index.set("journal", FileEvents.journalID(device: device) ?? "")
            }
            if changed { try saveRevision(sample: false) }
        }
        try scheduleRepairs()
        try wakeFootprints()
    }

    private func scheduleRepairs(after delay: Double = 0.02) throws {
        guard !repairScheduled else { return }
        guard try index.nextRepair() != nil else {
            if phase != .monitoring { publish(.monitoring) }
            if footprintsComplete { cacheReleaseTimer?.schedule(deadline: .now() + .seconds(8), leeway: .seconds(1)) }
            return
        }
        if phase != .recovering {
            scanner.resetProgress()
            publish(.recovering)
        }
        repairScheduled = true
        worker.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.repairScheduled = false
            do {
                self.restartIfAccessChanged()
                let started = ProcessInfo.processInfo.systemUptime
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                try self.index.checkDiskSpace()
                try self.index.db.transaction("BEGIN IMMEDIATE") {
                    for _ in 0..<(lowPower ? 4 : 12) {
                        guard let job = try self.index.nextRepair() else { break }
                        try self.scanner.repair(job.key, mode: job.mode)
                        if ProcessInfo.processInfo.systemUptime - started > 0.065 { break }
                    }
                    try self.saveRevision(sample: false)
                }
                let pause = (ProcessInfo.processInfo.systemUptime - started) * (lowPower ? 3 : 1.25)
                try self.scheduleRepairs(after: min(0.65, max(0.03, pause)))
                try self.wakeFootprints()
            } catch { self.fail(error) }
        }
    }

    private func monitorMemoryPressure() {
        let idle = DispatchSource.makeTimerSource(queue: worker)
        idle.schedule(deadline: .distantFuture)
        idle.setEventHandler { [weak self] in
            guard let self, self.phase == .monitoring, self.footprintsComplete, !self.repairScheduled else { return }
            self.index.db.releaseMemory()
        }
        idle.activate()
        cacheReleaseTimer = idle

        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: worker)
        pressure.setEventHandler { [weak self] in self?.index.db.releaseMemory() }
        pressure.activate()
        memoryPressure = pressure
    }

    private func wakeFootprints() throws {
        if footprintsComplete { footprintsComplete = try !index.footprints.hasPeerJobs() }
        scheduleFootprints()
    }

    private func scheduleFootprints(retry: Bool = false, after previousWork: Double = 0) {
        guard !footprintScheduled, !footprintsComplete else { return }
        footprintScheduled = true
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let delay = retry ? 60 : (lowPower ? 0.8 : min(0.75, max(0.15, previousWork * 1.5)))
        worker.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.footprintScheduled = false
            do {
                self.restartIfAccessChanged()
                let started = ProcessInfo.processInfo.systemUptime
                try self.index.checkDiskSpace()
                let work = try self.index.db.transaction("BEGIN IMMEDIATE") {
                    let peers = try self.index.footprints.nextPeerPage(limit: lowPower ? 24 : 96)
                    var peerChanged = false
                    for key in peers ?? [] {
                        if try self.scanner.refreshPeer(key) { peerChanged = true }
                    }
                    let page = try self.index.footprints.fillPage(limit: lowPower ? 96 : 512,
                                                                  preferPriority: self.footprintTurn != 3) {
                        self.scanner.footprint(for: $0, inode: $1)
                    }
                    let advanced = page.advanced || peers != nil
                    var pending = self.footprintRevisionPending || page.changed || peerChanged
                    let publish = pending && (!advanced || self.lastFootprintRevision.duration(to: .now) >= .seconds(2))
                    if publish {
                        try self.saveRevision(sample: false, touchedFiles: peerChanged)
                        pending = false
                    }
                    return (advanced, publish, pending)
                }
                self.footprintsComplete = !work.0
                self.footprintTurn = (self.footprintTurn + 1) % 4
                if work.1 { self.lastFootprintRevision = .now }
                self.footprintRevisionPending = work.2
                try self.scheduleRepairs()
                self.scheduleFootprints(after: ProcessInfo.processInfo.systemUptime - started)
            } catch {
                self.footprintsComplete = false
                self.logger.notice("Misure in background rimandate: \(error.localizedDescription, privacy: .private)")
                self.scheduleFootprints(retry: true)
            }
        }
    }

    private func maintenance(manual: Bool) {
        guard scanner != nil else { return }
        restartIfAccessChanged()
        if !manual && ProcessInfo.processInfo.isLowPowerModeEnabled {
            do {
                try index.db.transaction("BEGIN IMMEDIATE") { try saveRevision(sample: true, touchedFiles: false) }
            } catch { fail(error) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if manual {
            guard now - lastManualCheck >= 5 else { return }
            lastManualCheck = now
        }
        publish(.checking)
        do {
            let cutoff: Date = manual ? .distantFuture : Date()
            let gaps = try index.gaps(limit: manual ? 128 : 12, dueBefore: cutoff)
            for key in gaps {
                try index.db.transaction("BEGIN IMMEDIATE") { try scanner.audit(key, verifyAllocation: manual) }
            }
            let cursor = try index.metadata("auditPath") ?? ""
            let paths = try index.auditPaths(after: cursor, limit: 12)
            for path in paths {
                try index.db.transaction("BEGIN IMMEDIATE") {
                    try scanner.audit(EntryKey(tree: .data, path: path), verifyAllocation: true)
                    try index.set("auditPath", path)
                }
            }
            try index.db.transaction("BEGIN IMMEDIATE") {
                if paths.count < 12 { try index.set("auditPath", "") }
                try index.set("checked", String(Date().timeIntervalSince1970))
                try saveRevision(sample: true)
            }
            try scheduleRepairs()
            try wakeFootprints()
        } catch { fail(error) }
        guard phase == .monitoring else { return }
        do {
            try index.reclaimSpace()
            if try !index.compactParents && IndexMigration.isEligible(index.db, in: support) {
                // Restart at a committed FSEvents cursor. The new process can replace
                // the database without leaving an open SQLite writer behind.
                exit(EXIT_SUCCESS)
            }
        } catch {
            logger.notice("Compattazione rimandata: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func restartIfAccessChanged() {
        guard requestedAccess == .complete, SpaceTrailPaths.fixtureRoot == nil,
              ContinuousClock.now >= nextAccessCheck else { return }
        nextAccessCheck = .now + .seconds(5)
        if requestedAccess.effective != access { exit(EXIT_SUCCESS) }
    }

    private func saveRevision(sample: Bool, touchedFiles: Bool = true) throws {
        let now = Date()
        if touchedFiles { try index.set("updated", String(now.timeIntervalSince1970)) }
        if sample {
            let space = try mountInfo(VolumeTree.data.root)
            try index.recordSample(capacity: space.capacity, available: space.available, now: now)
        }
        try index.set("revision", UUID().uuidString)
    }

    private func publish(_ phase: BrokerState.Phase, processed: Int64 = 0, detail: String? = nil) {
        self.phase = phase
        let fraction = phase == .scanning && scanTotal > 0
            ? min(Double(processed) / Double(scanTotal), 0.99) : nil
        let elapsed = ProcessInfo.processInfo.systemUptime - scanStarted
        let remaining: Double? = phase == .scanning && elapsed >= 5 && processed > scanStartCount && processed < scanTotal
            ? Double(scanTotal - processed) * elapsed / Double(processed - scanStartCount) : nil
        do {
            try BrokerState(phase: phase, processed: processed, detail: detail,
                            fraction: fraction, secondsRemaining: remaining,
                            resumed: phase == .scanning && scanStartCount > 0,
                            background: parentPID == nil, build: build, effectiveAccess: access).write(in: support)
        }
        catch { logger.error("Stato broker: \(error.localizedDescription, privacy: .private)") }
    }

    private func fail(_ error: Error) -> Never {
        logger.error("\(error.localizedDescription, privacy: .private)")
        try? index?.db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        publish(.failed, detail: error.localizedDescription)
        // The cursor and the index share a transaction. Launchd can retry safely from the last commit.
        exit(EXIT_FAILURE)
    }
}

public struct BrokerAlreadyRunning: Error {}

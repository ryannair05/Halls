import CryptoKit
import Foundation
import Darwin

enum DiningContentHasher {
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)

    static func hash(_ data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    static func hash(_ value: String) -> String {
        var hasher = SHA256()
        updateBytes(of: value, in: &hasher)
        return hexadecimal(hasher.finalize())
    }

    static func hash<S: Sequence>(
        _ firstValue: String,
        followedBy remainingValues: S
    ) -> String where S.Element == String {
        var hasher = SHA256()
        update(firstValue, in: &hasher)
        for value in remainingValues { update(value, in: &hasher) }
        return hexadecimal(hasher.finalize())
    }

    private static func update(_ value: String, in hasher: inout SHA256) {
        let byteCount = value.utf8.count
        var length = UInt64(byteCount).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        updateBytes(of: value, byteCount: byteCount, in: &hasher)
    }

    private static func updateBytes(
        of value: String,
        byteCount: Int? = nil,
        in hasher: inout SHA256
    ) {
        let byteCount = byteCount ?? value.utf8.count
        value.withCString { pointer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: pointer,
                count: byteCount
            ))
        }
    }

    private static func hexadecimal<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        var result: [UInt8] = []
        result.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            result.append(hexadecimalDigits[Int(byte >> 4)])
            result.append(hexadecimalDigits[Int(byte & 0x0F)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Ordered menu identity. Transport validators, fetch times, diagnostics, URLs, and detail
    /// payloads are deliberately excluded; they cannot cause user-visible menu publication.
    static func semanticFingerprint(for snapshot: MenuDaySnapshot) -> String {
        var hasher = SHA256()
        update(snapshot.key.locationID.provider.rawValue, in: &hasher)
        update(snapshot.key.locationID.rawValue, in: &hasher)
        update(snapshot.key.localDate.description, in: &hasher)
        update(snapshot.key.sourceVariant, in: &hasher)
        update(String(snapshot.meals.count), in: &hasher)
        for meal in snapshot.meals {
            update(meal.id, in: &hasher)
            update(meal.displayName, in: &hasher)
            update(String(meal.sourceOrder), in: &hasher)
            update(String(meal.sections.count), in: &hasher)
            for section in meal.sections {
                update(section.id, in: &hasher)
                update(section.displayName, in: &hasher)
                update(String(section.sourceOrder), in: &hasher)
                update(String(section.items.count), in: &hasher)
                for item in section.items {
                    update(item.id, in: &hasher)
                    update(item.displayName, in: &hasher)
                    update(String(item.sourceOrder), in: &hasher)
                    update(String(item.sourceLabels.count), in: &hasher)
                    for label in item.sourceLabels { update(label, in: &hasher) }
                }
            }
        }
        return hexadecimal(hasher.finalize())
    }
}

enum MenuSnapshotStoreError: Error, Sendable, Equatable {
    case unsupportedSnapshotSchema(Int)
}

actor MenuSnapshotFileStore {
    static let directorySchemaVersion = 3

    private struct Manifest: Codable {
        struct Entry: Codable {
            let contentHash: String
            let semanticFingerprint: String
            let updatedAt: Date
        }

        let schemaVersion: Int
        var entries: [String: Entry]

        static let empty = Manifest(schemaVersion: directorySchemaVersion, entries: [:])
    }

    // Files are atomically replaced by the app and extensions. An inode + nanosecond
    // change stamp avoids JSON decoding on warm reads without a cross-process TTL.
    private struct FileStamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &info)
            }
            guard result == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }
    private struct DecodedEntry {
        let stamp: FileStamp
        let snapshot: MenuDaySnapshot
    }
    private var decodedSnapshots: [URL: DecodedEntry] = [:]
    private var decodedAccessOrder: [URL] = []

    func clearMemoryCache() {
        decodedSnapshots.removeAll(keepingCapacity: false)
        decodedAccessOrder.removeAll(keepingCapacity: false)
    }

    private func remember(_ snapshot: MenuDaySnapshot, at url: URL, stamp: FileStamp) {
        decodedSnapshots[url] = DecodedEntry(stamp: stamp, snapshot: snapshot)
        touchDecoded(url)
        while decodedAccessOrder.count > 10 {
            decodedSnapshots[decodedAccessOrder.removeFirst()] = nil
        }
    }

    private func touchDecoded(_ url: URL) {
        if let index = decodedAccessOrder.firstIndex(of: url) { decodedAccessOrder.remove(at: index) }
        decodedAccessOrder.append(url)
    }

    private let rootDirectory: URL
    private let sharedAcrossProcesses: Bool
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedManifest: Manifest?
    private var manifestFlushTask: Task<Void, Never>?

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default, sharedAcrossProcesses: Bool = false) {
        self.sharedAcrossProcesses = sharedAcrossProcesses
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            self.rootDirectory = URL.cachesDirectory
                .appending(
                    components: "MeetAndEat", "Dining", "v\(Self.directorySchemaVersion)",
                    directoryHint: .isDirectory
                )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func snapshot(for key: MenuDayKey) -> MenuDaySnapshot? {
        guard let snapshot = loadSnapshot(
            at: fileURL(for: key),
            expectedKey: key,
            removeManifestOnFailure: true
        ) else {
            return nil
        }
        if sharedAcrossProcesses { return snapshot }
        let manifestEntry = loadManifest().entries[manifestKey(for: key)]
        guard let manifestEntry,
              manifestEntry.contentHash == snapshot.sourceContentHash,
              manifestEntry.updatedAt > snapshot.fetchedAt else {
            return snapshot
        }
        return MenuDaySnapshot(
            schemaVersion: snapshot.schemaVersion,
            key: snapshot.key,
            fetchedAt: manifestEntry.updatedAt,
            sourceContentHash: snapshot.sourceContentHash,
            meals: snapshot.meals
        )
    }

    func lastKnownGoodSnapshot(for key: MenuDayKey) -> MenuDaySnapshot? {
        guard let snapshot = loadSnapshot(
            at: lastKnownGoodFileURL(for: key),
            expectedKey: key,
            removeManifestOnFailure: false
        ), snapshot.hasPublishedItems else {
            return nil
        }
        return snapshot
    }

    private func loadSnapshot(
        at url: URL,
        expectedKey: MenuDayKey,
        removeManifestOnFailure: Bool
    ) -> MenuDaySnapshot? {
        guard let stamp = FileStamp(url) else {
            decodedSnapshots[url] = nil
            return nil
        }
        if let cached = decodedSnapshots[url], cached.stamp == stamp, cached.snapshot.key == expectedKey {
            touchDecoded(url)
            return cached.snapshot
        }
        decodedSnapshots[url] = nil
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let snapshot = try decoder.decode(MenuDaySnapshot.self, from: data)
            guard snapshot.schemaVersion == MenuDaySnapshot.currentSchemaVersion,
                  snapshot.key == expectedKey else {
                if FileStamp(url) == stamp { try? fileManager.removeItem(at: url) }
                if removeManifestOnFailure {
                    try? removeManifestEntry(for: expectedKey)
                }
                return nil
            }
            // A writer may replace the file during this read. Return the complete decoded
            // value, but never associate it with a different file's stamp.
            if FileStamp(url) == stamp { remember(snapshot, at: url, stamp: stamp) }
            return snapshot
        } catch {
            if FileStamp(url) == stamp { try? fileManager.removeItem(at: url) }
            if removeManifestOnFailure {
                try? removeManifestEntry(for: expectedKey)
            }
            return nil
        }
    }

    @discardableResult
    func store(_ newSnapshot: MenuDaySnapshot) throws -> Bool {
        guard newSnapshot.schemaVersion == MenuDaySnapshot.currentSchemaVersion else {
            throw MenuSnapshotStoreError.unsupportedSnapshotSchema(newSnapshot.schemaVersion)
        }
        if sharedAcrossProcesses {
            // A complete, atomically replaced file is the cross-process source of truth.
            // The single-process manifest optimization cannot safely coordinate two writers.
            let existing = snapshot(for: newSnapshot.key)
            if let existing, existing.fetchedAt > newSnapshot.fetchedAt { return false }
            if let existing, existing.hasPublishedItems, !newSnapshot.hasPublishedItems {
                try writeAtomically(encoder.encode(existing), to: lastKnownGoodFileURL(for: newSnapshot.key))
            }
            let changed = existing.map { DiningContentHasher.semanticFingerprint(for: $0) }
                != DiningContentHasher.semanticFingerprint(for: newSnapshot)
            if existing != newSnapshot {
                try writeAtomically(encoder.encode(newSnapshot), to: fileURL(for: newSnapshot.key))
            }
            return changed
        }
        let destination = fileURL(for: newSnapshot.key)
        let entryKey = manifestKey(for: newSnapshot.key)
        let existingEntry = loadManifest().entries[entryKey]
        let fingerprint = DiningContentHasher.semanticFingerprint(for: newSnapshot)
        let semanticChanged = existingEntry?.semanticFingerprint != fingerprint

        if !semanticChanged {
            try ensureManifestEntry(
                for: newSnapshot.key,
                snapshotContentHash: existingEntry?.contentHash ?? newSnapshot.sourceContentHash,
                semanticFingerprint: fingerprint,
                validatedAt: newSnapshot.fetchedAt,
                flushImmediately: false
            )
            return false
        }

        if !newSnapshot.hasPublishedItems,
           let existing = snapshot(for: newSnapshot.key),
           existing.hasPublishedItems {
            try writeAtomically(
                encoder.encode(existing),
                to: lastKnownGoodFileURL(for: newSnapshot.key)
            )
        }
        let data = try encoder.encode(newSnapshot)
        try writeAtomically(data, to: destination)
        if newSnapshot.hasPublishedItems {
            let lastGood = lastKnownGoodFileURL(for: newSnapshot.key)
            if fileManager.fileExists(atPath: lastGood.path(percentEncoded: false)) {
                try fileManager.removeItem(at: lastGood)
            }
        }
        try ensureManifestEntry(
            for: newSnapshot.key,
            snapshotContentHash: newSnapshot.sourceContentHash,
            semanticFingerprint: fingerprint,
            validatedAt: newSnapshot.fetchedAt,
            flushImmediately: true
        )
        return true
    }

    func invalidate(_ key: MenuDayKey) throws {
        let url = fileURL(for: key)
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            if let snapshot = loadSnapshot(
                at: url,
                expectedKey: key,
                removeManifestOnFailure: false
            ), snapshot.hasPublishedItems {
                try writeAtomically(
                    encoder.encode(snapshot),
                    to: lastKnownGoodFileURL(for: key)
                )
            }
            try fileManager.removeItem(at: url)
        }
        if !sharedAcrossProcesses { try removeManifestEntry(for: key) }
    }

    @discardableResult
    func prune(
        provider: DiningProviderID,
        keeping localDates: Set<DateOnly>
    ) throws -> Int {
        if sharedAcrossProcesses {
            let doomed = storedKeys(provider: provider).filter { !localDates.contains($0.localDate) }
            for key in doomed {
                for url in [fileURL(for: key), lastKnownGoodFileURL(for: key)]
                where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: url)
                }
            }
            return doomed.count
        }
        var manifest = loadManifest()
        let doomed = manifest.entries.keys.compactMap { entryKey -> (String, MenuDayKey)? in
            guard let key = parsedManifestKey(entryKey),
                  key.locationID.provider == provider,
                  !localDates.contains(key.localDate) else { return nil }
            return (entryKey, key)
        }
        for (entryKey, key) in doomed {
            for url in [fileURL(for: key), lastKnownGoodFileURL(for: key)]
            where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try fileManager.removeItem(at: url)
            }
            manifest.entries[entryKey] = nil
        }
        guard !doomed.isEmpty else { return 0 }
        cachedManifest = manifest
        manifestFlushTask?.cancel()
        try writeAtomically(encoder.encode(manifest), to: manifestURL)
        return doomed.count
    }

    func storedKeys(provider: DiningProviderID) -> [MenuDayKey] {
        if sharedAcrossProcesses {
            let providerRoot = rootDirectory.appending(component: provider.rawValue)
            guard let enumerator = fileManager.enumerator(at: providerRoot, includingPropertiesForKeys: nil) else { return [] }
            var keys: [MenuDayKey] = []
            for case let url as URL in enumerator where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? decoder.decode(MenuDaySnapshot.self, from: data),
                      snapshot.schemaVersion == MenuDaySnapshot.currentSchemaVersion,
                      snapshot.key.locationID.provider == provider else { continue }
                keys.append(snapshot.key)
            }
            return keys.sorted {
                if $0.localDate != $1.localDate { return $0.localDate < $1.localDate }
                return $0.locationID.rawValue < $1.locationID.rawValue
            }
        }
        return loadManifest().entries.keys.compactMap(parsedManifestKey).filter {
            $0.locationID.provider == provider
        }.sorted {
            if $0.localDate != $1.localDate { return $0.localDate < $1.localDate }
            if $0.locationID.rawValue != $1.locationID.rawValue {
                return $0.locationID.rawValue < $1.locationID.rawValue
            }
            return $0.sourceVariant < $1.sourceVariant
        }
    }

    func fileURL(for key: MenuDayKey) -> URL {
        rootDirectory.appending(
            components: key.locationID.provider.rawValue, key.locationID.rawValue, fileName(for: key),
            directoryHint: .notDirectory
        )
    }

    func lastKnownGoodFileURL(for key: MenuDayKey) -> URL {
        rootDirectory.appending(
            components: "last-good", key.locationID.provider.rawValue, key.locationID.rawValue, fileName(for: key),
            directoryHint: .notDirectory
        )
    }

    private var manifestURL: URL {
        rootDirectory.appending(path: "metadata/manifest.json", directoryHint: .notDirectory)
    }

    private func loadManifest() -> Manifest {
        if let cachedManifest { return cachedManifest }
        guard let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
              let manifest = try? decoder.decode(Manifest.self, from: data),
              manifest.schemaVersion == Self.directorySchemaVersion else {
            cachedManifest = .empty
            return .empty
        }
        cachedManifest = manifest
        return manifest
    }

    private func manifestKey(for key: MenuDayKey) -> String {
        "\(key.locationID.provider.rawValue)/\(key.locationID.rawValue)/\(key.localDate.description)/\(key.sourceVariant)"
    }

    private func parsedManifestKey(_ value: String) -> MenuDayKey? {
        let components = value.split(separator: "/", maxSplits: 3).map(String.init)
        guard components.count == 4 else { return nil }
        let dateParts = components[2].split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3,
              let date = DateOnly(
                  year: dateParts[0],
                  month: dateParts[1],
                  day: dateParts[2]
              ) else { return nil }
        return MenuDayKey(
            locationID: DiningLocationID(
                provider: DiningProviderID(rawValue: components[0]),
                rawValue: components[1]
            ),
            localDate: date,
            sourceVariant: components[3]
        )
    }

    private func fileName(for key: MenuDayKey) -> String {
        guard key.sourceVariant != MenuDayKey.officialSourceVariant else {
            return "\(key.localDate.description).json"
        }
        return "\(key.localDate.description)--\(key.sourceVariant).json"
    }

    private func ensureManifestEntry(
        for key: MenuDayKey,
        snapshotContentHash: String,
        semanticFingerprint: String,
        validatedAt: Date,
        flushImmediately: Bool
    ) throws {
        var manifest = loadManifest()
        let entryKey = manifestKey(for: key)
        if let existing = manifest.entries[entryKey],
           existing.contentHash == snapshotContentHash,
           existing.semanticFingerprint == semanticFingerprint,
           existing.updatedAt >= validatedAt {
            return
        }
        manifest.entries[entryKey] = Manifest.Entry(
            contentHash: snapshotContentHash,
            semanticFingerprint: semanticFingerprint,
            updatedAt: validatedAt
        )
        cachedManifest = manifest
        if flushImmediately {
            manifestFlushTask?.cancel()
            try writeManifest()
        } else {
            scheduleManifestFlush()
        }
    }

    private func removeManifestEntry(for key: MenuDayKey) throws {
        var manifest = loadManifest()
        guard manifest.entries.removeValue(forKey: manifestKey(for: key)) != nil else {
            return
        }
        cachedManifest = manifest
        manifestFlushTask?.cancel()
        try writeManifest()
    }

    private func scheduleManifestFlush() {
        manifestFlushTask?.cancel()
        let operation: @isolated(any) () async -> Void = flushManifestAfterDelay
        manifestFlushTask = Task(operation: operation)
    }

    private func flushManifestAfterDelay() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        try? writeManifest()
    }

    private func writeManifest() throws {
        guard let cachedManifest else { return }
        try writeAtomically(encoder.encode(cachedManifest), to: manifestURL)
        manifestFlushTask = nil
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}

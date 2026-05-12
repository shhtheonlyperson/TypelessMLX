import Foundation

public struct HuggingFaceModelCache {
    public let hubRoot: URL
    private let fileManager: FileManager

    public init(
        hubRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub"),
        fileManager: FileManager = .default
    ) {
        self.hubRoot = hubRoot
        self.fileManager = fileManager
    }

    public func cacheDirectory(forRepoID repoID: String) -> URL {
        hubRoot.appendingPathComponent("models--\(Self.sanitizedRepoID(repoID))")
    }

    public func cachedSize(forRepoID repoID: String) -> Int64 {
        let root = cacheDirectory(forRepoID: repoID)
        // HuggingFace loaders consume snapshots; blobs alone can be orphaned or partial.
        let snapshotRoots = usableSnapshotDirectories(in: root)
        guard !snapshotRoots.isEmpty else { return 0 }
        return snapshotRoots.reduce(into: SnapshotSize()) { partial, snapshotRoot in
            partial.addFiles(from: snapshotRoot, fileManager: fileManager)
        }.bytes
    }

    public func isCached(repoID: String) -> Bool {
        cachedSize(forRepoID: repoID) > 0
    }

    public static func sanitizedRepoID(_ repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "--")
    }

    private func usableSnapshotDirectories(in cacheRoot: URL) -> [URL] {
        let snapshotsRoot = cacheRoot.appendingPathComponent("snapshots")
        guard let snapshotNames = try? fileManager.contentsOfDirectory(atPath: snapshotsRoot.path) else {
            return []
        }

        return snapshotNames
            .map { snapshotsRoot.appendingPathComponent($0) }
            .filter { snapshotHasReachableModelFiles($0) }
    }

    private func snapshotHasReachableModelFiles(_ snapshotRoot: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: snapshotRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator where isReachableFile(fileURL) {
            return true
        }
        return false
    }

    private func isReachableFile(_ fileURL: URL) -> Bool {
        guard !fileURL.lastPathComponent.hasSuffix(".incomplete") else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && resolvedFileSize(fileURL) > 0
    }

    private func resolvedFileSize(_ fileURL: URL) -> Int64 {
        if let symlinkDestination = try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path) {
            let resolvedURL: URL
            if symlinkDestination.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: symlinkDestination)
            } else {
                resolvedURL = fileURL.deletingLastPathComponent().appendingPathComponent(symlinkDestination)
            }
            return Self.fileSize(resolvedURL, fileManager: fileManager)
        }
        return Self.fileSize(fileURL, fileManager: fileManager)
    }

    private struct SnapshotSize {
        var bytes: Int64 = 0
        private var countedPaths: Set<String> = []

        mutating func addFiles(from snapshotRoot: URL, fileManager: FileManager) {
            guard let enumerator = fileManager.enumerator(
                at: snapshotRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for case let fileURL as URL in enumerator {
                guard !fileURL.lastPathComponent.hasSuffix(".incomplete") else { continue }
                guard let resolvedURL = Self.resolvedFileURL(fileURL, fileManager: fileManager) else { continue }
                let path = resolvedURL.standardizedFileURL.path
                guard countedPaths.insert(path).inserted else { continue }
                bytes += HuggingFaceModelCache.fileSize(resolvedURL, fileManager: fileManager)
            }
        }

        private static func resolvedFileURL(_ fileURL: URL, fileManager: FileManager) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return nil
            }

            if let symlinkDestination = try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path) {
                if symlinkDestination.hasPrefix("/") {
                    return URL(fileURLWithPath: symlinkDestination)
                }
                return fileURL.deletingLastPathComponent().appendingPathComponent(symlinkDestination)
            }
            return fileURL
        }
    }

    private static func fileSize(_ fileURL: URL, fileManager: FileManager) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

public enum ModelDirectorySize {
    public static func bytes(at url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

import Foundation
import TypelessMLXModelCacheSupport

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError(message)
    }
}

func temporaryHubRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TypelessMLXModelCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func testRepoIDIsSanitizedLikeHuggingFaceHubCache() {
    expect(
        HuggingFaceModelCache.sanitizedRepoID("mlx-community/whisper-large-v3-mlx")
            == "mlx-community--whisper-large-v3-mlx",
        "repo IDs should use HuggingFace hub cache directory format"
    )
}

func testBlobsWithoutUsableSnapshotAreNotConsideredCached() throws {
    let root = try temporaryHubRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let cache = HuggingFaceModelCache(hubRoot: root)
    let modelRoot = cache.cacheDirectory(forRepoID: "schsu/breeze-asr-25-mlx")
    let blobs = modelRoot.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try Data(repeating: 0x01, count: 2048).write(to: blobs.appendingPathComponent("orphan-blob"))

    expect(
        cache.cachedSize(forRepoID: "schsu/breeze-asr-25-mlx") == 0,
        "orphan blobs should not count as a downloaded model"
    )
    expect(
        !cache.isCached(repoID: "schsu/breeze-asr-25-mlx"),
        "cache status should require a usable snapshot"
    )
}

func testSnapshotSymlinkToBlobIsTheCacheSourceOfTruth() throws {
    let root = try temporaryHubRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let cache = HuggingFaceModelCache(hubRoot: root)
    let modelRoot = cache.cacheDirectory(forRepoID: "mlx-community/whisper-large-v3-mlx")
    let blob = modelRoot.appendingPathComponent("blobs/weights")
    let snapshot = modelRoot.appendingPathComponent("snapshots/revision-a")
    let snapshotFile = snapshot.appendingPathComponent("weights.safetensors")

    try FileManager.default.createDirectory(
        at: blob.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data(repeating: 0x02, count: 4096).write(to: blob)
    try FileManager.default.createSymbolicLink(
        atPath: snapshotFile.path,
        withDestinationPath: "../../blobs/weights"
    )

    expect(
        cache.cachedSize(forRepoID: "mlx-community/whisper-large-v3-mlx") == 4096,
        "reachable snapshot files should report the resolved blob size"
    )
    expect(
        cache.isCached(repoID: "mlx-community/whisper-large-v3-mlx"),
        "a snapshot symlink to a real blob should count as cached"
    )
}

func testBrokenSnapshotSymlinkIsNotConsideredCached() throws {
    let root = try temporaryHubRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let cache = HuggingFaceModelCache(hubRoot: root)
    let snapshot = cache.cacheDirectory(forRepoID: "mlx-community/whisper-small-mlx")
        .appendingPathComponent("snapshots/revision-a")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: snapshot.appendingPathComponent("weights.safetensors").path,
        withDestinationPath: "../../blobs/missing"
    )

    expect(
        cache.cachedSize(forRepoID: "mlx-community/whisper-small-mlx") == 0,
        "broken snapshot symlinks should not count as downloaded"
    )
    expect(
        !cache.isCached(repoID: "mlx-community/whisper-small-mlx"),
        "broken snapshots should not count as cached"
    )
}

func testCopiedSnapshotFilesAreAlsoSupported() throws {
    let root = try temporaryHubRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let cache = HuggingFaceModelCache(hubRoot: root)
    let snapshot = cache.cacheDirectory(forRepoID: "mlx-community/Qwen3-ASR-0.6B-8bit")
        .appendingPathComponent("snapshots/revision-a")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data(repeating: 0x03, count: 3072)
        .write(to: snapshot.appendingPathComponent("model.safetensors"))

    expect(
        cache.cachedSize(forRepoID: "mlx-community/Qwen3-ASR-0.6B-8bit") == 3072,
        "copied snapshot files should also be counted"
    )
    expect(
        cache.isCached(repoID: "mlx-community/Qwen3-ASR-0.6B-8bit"),
        "copied snapshot files should count as cached"
    )
}

testRepoIDIsSanitizedLikeHuggingFaceHubCache()
try testBlobsWithoutUsableSnapshotAreNotConsideredCached()
try testSnapshotSymlinkToBlobIsTheCacheSourceOfTruth()
try testBrokenSnapshotSymlinkIsNotConsideredCached()
try testCopiedSnapshotFilesAreAlsoSupported()

print("TypelessMLXModelCacheSupportTests passed")

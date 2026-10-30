import Foundation

/// A `MediaCacheStore` bound to one `CacheScope`, published alongside the
/// connected client so view models read and write the active user's cache
/// without re-plumbing the scope per call.
public struct ScopedCache: Sendable {
    public let store: MediaCacheStore
    public let scope: CacheScope

    /// The purges this handle has seen. A write through a handle made before
    /// its scope was purged is dropped, so an in-flight write from an ended
    /// session can't land after its purge.
    public let mark: CacheWriteMark

    public init(store: MediaCacheStore, scope: CacheScope) {
        self.store = store
        self.scope = scope
        mark = store.writeMark()
    }

    public func read<T: Decodable & Sendable>(_ type: T.Type, key: CacheSnapshotKey) async -> T? {
        await store.read(type, scope: scope, key: key)
    }

    public func write(_ value: some Encodable & Sendable, key: CacheSnapshotKey) async {
        await store.write(value, scope: scope, key: key, since: mark)
    }
}

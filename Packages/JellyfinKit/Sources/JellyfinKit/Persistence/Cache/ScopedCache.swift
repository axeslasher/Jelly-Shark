import Foundation

/// A `MediaCacheStore` bound to one `CacheScope`, published alongside the
/// connected client so view models read and write the active user's cache
/// without re-plumbing the scope per call.
public struct ScopedCache: Sendable {
    public let store: MediaCacheStore
    public let scope: CacheScope

    public init(store: MediaCacheStore, scope: CacheScope) {
        self.store = store
        self.scope = scope
    }

    public func read<T: Decodable & Sendable>(_ type: T.Type, key: CacheSnapshotKey) async -> T? {
        await store.read(type, scope: scope, key: key)
    }

    public func write(_ value: some Encodable & Sendable, key: CacheSnapshotKey) async {
        await store.write(value, scope: scope, key: key)
    }
}

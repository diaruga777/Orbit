import Foundation

/// Last successful display data for one authenticated Mac. Never used as proof
/// of reachability, an accepted job, or a confirmed installation.
public struct OrbitPageCache {
    private let defaults: UserDefaults
    private let key: String
    public init(key: String, defaults: UserDefaults = .standard) {
        self.key = key; self.defaults = defaults
    }
    public func load(peer: String) -> Data? {
        guard !peer.isEmpty, peer != "unpaired",
              let record = defaults.dictionary(forKey: key), record["peer"] as? String == peer else { return nil }
        return record["data"] as? Data
    }
    public func save(_ data: Data, peer: String) {
        guard !peer.isEmpty, peer != "unpaired" else { return }
        defaults.set(["peer": peer, "data": data], forKey: key)
    }
}

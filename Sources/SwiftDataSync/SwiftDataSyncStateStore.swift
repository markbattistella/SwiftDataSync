//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// Persists the engine's tracked zones and opaque CloudKit sync state between
/// launches.
///
/// Values are small and opaque. Implement this to redirect them somewhere
/// other than `UserDefaults`, such as the keychain or a test double.
///
/// - Important: Implementations are main-actor isolated, matching the engine
///   that drives them.
@MainActor
public protocol SwiftDataSyncStateStore: AnyObject {

    /// Returns the data stored for an engine key.
    ///
    /// - Parameter key: The key to read.
    /// - Returns: The stored data, or `nil` when the key is absent.
    func data(forKey key: String) -> Data?

    /// Returns the string stored for an engine key.
    ///
    /// - Parameter key: The key to read.
    /// - Returns: The stored string, or `nil` when the key is absent.
    func string(forKey key: String) -> String?

    /// Stores data for an engine key.
    ///
    /// - Parameters:
    ///   - value: The data to store.
    ///   - key: The key to write.
    func set(_ value: Data, forKey key: String)

    /// Stores a string for an engine key.
    ///
    /// - Parameters:
    ///   - value: The string to store.
    ///   - key: The key to write.
    func set(_ value: String, forKey key: String)

    /// Removes the value stored for an engine key.
    ///
    /// - Parameter key: The key to remove.
    func removeValue(forKey key: String)
}

/// A `UserDefaults`-backed engine-state store.
///
/// The default store, used when no custom one is supplied.
@MainActor
public final class UserDefaultsSwiftDataSyncStateStore:
    SwiftDataSyncStateStore
{

    /// The defaults suite backing this store.
    private let defaults: UserDefaults

    /// Creates a state store using the configuration's app group.
    ///
    /// Falls back to `UserDefaults.standard` when the configuration names no
    /// app group, or when its suite can't be opened.
    ///
    /// - Parameter configuration: The shared-store configuration.
    public init(configuration: SwiftDataSyncConfiguration) {
        if let identifier = configuration.appGroupIdentifier,
            let defaults = UserDefaults(suiteName: identifier)
        {
            self.defaults = defaults
        } else {
            self.defaults = .standard
        }
    }

    /// Creates a state store around an explicit defaults suite.
    ///
    /// - Parameter defaults: The defaults instance used for persistence.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the data stored for an engine key.
    ///
    /// - Parameter key: The key to read.
    /// - Returns: The stored data, or `nil` when the key is absent.
    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    /// Returns the string stored for an engine key.
    ///
    /// - Parameter key: The key to read.
    /// - Returns: The stored string, or `nil` when the key is absent.
    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    /// Stores data for an engine key.
    ///
    /// - Parameters:
    ///   - value: The data to store.
    ///   - key: The key to write.
    public func set(_ value: Data, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Stores a string for an engine key.
    ///
    /// - Parameters:
    ///   - value: The string to store.
    ///   - key: The key to write.
    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Removes the value stored for an engine key.
    ///
    /// - Parameter key: The key to remove.
    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

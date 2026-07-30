//
// Project: SwiftDataSync
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

/// Persists opaque engine state and the current sharing role between launches.
@MainActor
public protocol SwiftDataSyncStateStore: AnyObject {

  /// Returns data for a persisted engine key.
  func data(forKey key: String) -> Data?

  /// Returns a string for a persisted engine key.
  func string(forKey key: String) -> String?

  /// Stores data for an engine key.
  func set(_ value: Data, forKey key: String)

  /// Stores a string for an engine key.
  func set(_ value: String, forKey key: String)

  /// Removes a persisted engine key.
  func removeValue(forKey key: String)
}

/// A `UserDefaults`-backed engine-state store.
@MainActor
public final class UserDefaultsSwiftDataSyncStateStore:
  SwiftDataSyncStateStore
{

  private let defaults: UserDefaults

  /// Creates a state store using the configuration's app group when supplied.
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

  /// Creates a state store around an explicitly supplied defaults suite.
  ///
  /// - Parameter defaults: The defaults instance used for persistence.
  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  public func data(forKey key: String) -> Data? {
    defaults.data(forKey: key)
  }

  public func string(forKey key: String) -> String? {
    defaults.string(forKey: key)
  }

  public func set(_ value: Data, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: String, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func removeValue(forKey key: String) {
    defaults.removeObject(forKey: key)
  }
}

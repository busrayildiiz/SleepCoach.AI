import SwiftUI
import Combine

/// View invalidation only; the observer does not keep a second plaintext copy.
private final class SecureStoreObserver: ObservableObject {
    static let shared = SecureStoreObserver()
    private var subscription: AnyCancellable?

    private init() {
        subscription = NotificationCenter.default.publisher(for: .secureDataStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// AppStorage-style bindings backed by the encrypted vault. Form commits that
/// contain multiple fields use SecureDataStore.write to report success atomically.
@propertyWrapper
struct SecureStorage<Value>: DynamicProperty {
    @ObservedObject private var observer = SecureStoreObserver.shared
    private let key: String
    private let fallback: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        fallback = wrappedValue
    }

    var wrappedValue: Value {
        get { SecureDataStore.shared.object(forKey: key) as? Value ?? fallback }
        nonmutating set { SecureDataStore.shared.set(newValue, forKey: key) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

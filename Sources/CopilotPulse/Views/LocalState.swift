import SwiftUI

/// Same behavior as `@State`.
///
/// In the macOS 27 SDK, `@State` is a compiler macro whose plugin ships only with Xcode,
/// so it can't be built with the Command Line Tools alone. This wraps the underlying
/// `State` storage directly (SwiftUI finds nested dynamic properties), which builds anywhere.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}

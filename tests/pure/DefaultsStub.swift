// Minimal stand-in for the Defaults package so pure rule files compile without the app.
enum Defaults {
    protocol Serializable {}
    class _AnyKey {}
    class Keys: _AnyKey {}
    final class Key<T>: Keys { init(_ name: String, default: T) {} }
}
extension Defaults.Keys {
    static let enableClaudeProvider = Defaults.Key<Bool>("a", default: true)
    static let enableCodexProvider = Defaults.Key<Bool>("b", default: true)
    static let enableCursorProvider = Defaults.Key<Bool>("c", default: true)
    static let enableAntigravityProvider = Defaults.Key<Bool>("d", default: true)
    static let enableNewAPIProvider = Defaults.Key<Bool>("e", default: true)
}
struct NewAPIAccountSnapshot: Equatable, Identifiable { var id: Int }

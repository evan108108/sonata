import Foundation

/// Scalar-safe replacement for `JSONSerialization.data(withJSONObject:options:)`.
///
/// The Foundation API raises an **Objective-C** `NSInvalidArgumentException`
/// ("Invalid top-level type in JSON write") whenever the top-level value is a
/// scalar — `String`, `NSNumber` (including `Bool` / `Int` / `Double`), or
/// `NSNull` — instead of a container (`Array` / `Dictionary`). Swift `try` and
/// `try?` do **not** catch Objective-C exceptions, so such a call terminates
/// the whole process. This is the crash class that killed Sonata on
/// 2026-07-17 via the WhatHappened plugin-forward path (see `AnyJSONEncodable`
/// in `WhatHappenedActions.swift`, which fixes the same class for the Codable
/// re-encode position by walking the value tree instead of round-tripping).
///
/// Any code path that feeds an `Any` of *unknown* shape into JSON
/// serialization must go through this guard rather than calling the raw API.
/// The guard is Foundation's own `isValidJSONObject` predicate — which is
/// `true` only when the top level is a container **and** every leaf is
/// JSON-legal — so a scalar top-level (and any other unserializable graph,
/// e.g. one containing `NaN` or a non-JSON object) is rejected *before* the
/// raising call is ever reached. It therefore never raises: it returns `nil`
/// for exactly the inputs that would otherwise crash the process, and valid
/// `Data` for everything the raw API would have serialized successfully.
enum SafeJSON {

    /// Serialize `value` to JSON `Data`, returning `nil` (never crashing)
    /// instead of raising an uncatchable `NSException` on a scalar top-level
    /// or any other unserializable graph.
    static func data(
        withJSONObject value: Any,
        options: JSONSerialization.WritingOptions = []
    ) -> Data? {
        // `isValidJSONObject` returns false for a scalar top level — the exact
        // input that makes the raw call raise — so this guard makes the call
        // below provably non-raising.
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: options)
    }
}

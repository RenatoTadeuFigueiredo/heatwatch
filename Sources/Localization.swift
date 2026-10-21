import Foundation

/// Looks a UI string up in the bundle tables, falling back to English.
/// Separated so the call sites stay readable.
func L(_ key: String, _ fallback: String) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
}

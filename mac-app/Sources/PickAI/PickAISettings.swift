import Foundation

/// Shared, persisted Pick AI settings — backed by UserDefaults(standard), which every Pick AI
/// process (main and every clone) reads from and writes to the same per-user plist, so toggling
/// a setting from any one process's menu takes effect for all of them (each reads it fresh at
/// the point it's actually used, rather than caching it once at launch).
enum PickAISettings {
    private static let hideFromScreenshotsKey = "PickAI.hideFromScreenshots"

    /// Defaults to true (hidden) — Pick AI not capturing itself in a screenshot/recording is the
    /// safer default; showing up in captures is an opt-in debugging aid, not the normal mode.
    static var hideFromScreenshots: Bool {
        get { UserDefaults.standard.object(forKey: hideFromScreenshotsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hideFromScreenshotsKey) }
    }
}

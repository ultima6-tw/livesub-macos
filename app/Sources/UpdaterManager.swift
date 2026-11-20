import AppKit
import Combine
import Sparkle

/// Sparkle-based update checks against the GitHub release appcast
/// (`SUFeedURL` in Info.plist). Automatic checks stay off until the user
/// agrees — Sparkle asks on the second launch, or via the menu toggle.
///
/// JaSub is a menu bar (LSUIElement) app, so per Sparkle's "gentle reminders"
/// guidance the app temporarily becomes a regular Dock app while an update
/// alert is shown (otherwise the alert can end up behind other windows) and
/// goes back to accessory when the update session ends.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    @Published private(set) var canCheckForUpdates = false
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates` (persisted by Sparkle).
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: self)
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .removeDuplicates()
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        NSApp.activate()
        updater.checkForUpdates()
    }
}

extension UpdaterManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApp.setActivationPolicy(.accessory)
    }
}

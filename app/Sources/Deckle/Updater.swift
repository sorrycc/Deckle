import AppKit
import Sparkle

/// Updates from the appcast on GitHub Pages, through Sparkle. Only release
/// builds have a feed, so dev builds never replace themselves.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private nonisolated static let betaKey = "updateIncludesBetas"

    static var isAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    /// Betas are on Sparkle's `beta` channel, which only those who opt in see.
    static var includesBetas: Bool {
        get { UserDefaults.standard.bool(forKey: betaKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: betaKey)
            shared.controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        guard Self.isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaKey) ? ["beta"] : []
    }
}

extension Updater: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller?.updater.canCheckForUpdates ?? false }
}

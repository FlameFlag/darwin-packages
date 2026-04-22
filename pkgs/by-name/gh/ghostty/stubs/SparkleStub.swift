import Foundation
import AppKit

// Minimal Sparkle stub for Nix builds. Auto-update is managed by Nix.
// Keep this file as simple as possible, complex protocol definitions
// cause Swift 5.10's -emit-module to hang

public class SUAppcastItem: NSObject {
    public var displayVersionString: String { "" }
    public var contentLength: UInt64 { 0 }
    public var date: Date? { nil }
    public static func empty() -> SUAppcastItem { SUAppcastItem() }
}

public enum SPUUserUpdateChoice: Int {
    case install = 0
    case dismiss = 1
    case skip = 2
}

public class SPUDownloadData: NSObject {}
public class SPUUpdatePermissionRequest: NSObject {
    public init(systemProfile: [Any]) {}
}
public class SUUpdatePermissionResponse: NSObject {
    public let automaticUpdateChecks: Bool
    public let sendSystemProfile: Bool
    public init(automaticUpdateChecks: Bool, sendSystemProfile: Bool) {
        self.automaticUpdateChecks = automaticUpdateChecks
        self.sendSystemProfile = sendSystemProfile
    }
}
public class SPUUserUpdateState: NSObject {}

public protocol SPUUserDriver: AnyObject {
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void)
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void)
    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void)
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData)
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error)
    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void)
    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void)
    func showDownloadInitiated(cancellation: @escaping () -> Void)
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64)
    func showDownloadDidReceiveData(ofLength length: UInt64)
    func showDownloadDidStartExtractingUpdate()
    func showExtractionReceivedProgress(_ progress: Double)
    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void)
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void)
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                          acknowledgement: @escaping () -> Void)
    func showUpdateInFocus()
    func dismissUpdateInstallation()
}

public protocol SPUUpdaterDelegate: AnyObject {
    func feedURLString(for updater: SPUUpdater) -> String?
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool
    func updaterWillRelaunchApplication(_ updater: SPUUpdater)
}

// Default implementations so conformers only need to implement what they use
public extension SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { nil }
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool { false }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {}
}

public class SPUStandardUserDriver: NSObject {
    public init(hostBundle: Bundle, delegate: Any?) {}
    public func show(_ request: SPUUpdatePermissionRequest,
                     reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {}
    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    public func showUpdateFound(with appcastItem: SUAppcastItem,
                                state: SPUUserUpdateState,
                                reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {}
    public func showUpdateNotFoundWithError(_ error: any Error,
                                            acknowledgement: @escaping () -> Void) {}
    public func showUpdaterError(_ error: any Error,
                                 acknowledgement: @escaping () -> Void) {}
    public func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    public func showDownloadDidReceiveData(ofLength length: UInt64) {}
    public func showDownloadDidStartExtractingUpdate() {}
    public func showExtractionReceivedProgress(_ progress: Double) {}
    public func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {}
    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                     retryTerminatingApplication: @escaping () -> Void) {}
    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool,
                                                  acknowledgement: @escaping () -> Void) {}
    public func showUpdateInFocus() {}
    public func dismissUpdateInstallation() {}
}

public class SPUUpdater: NSObject {
    @objc dynamic public var automaticallyChecksForUpdates: Bool = false
    public var automaticallyDownloadsUpdates: Bool = false
    public var canCheckForUpdates: Bool { false }
    public init(hostBundle: Bundle, applicationBundle: Bundle, userDriver: SPUUserDriver, delegate: SPUUpdaterDelegate?) {}
    public func start() throws {}
    @objc public func checkForUpdates() {}
}

import Foundation
import SwiftUI
import AVFoundation
import CoreGraphics
import AppKit
import UserNotifications
import OSLog

/// Drives the onboarding permissions step. Tracks live status for the three
/// permissions the app needs (Microphone, Screen Recording, Notifications),
/// lets the user trigger the system prompt, and exposes deep links into
/// System Settings for cases where the user previously denied access (macOS
/// does not show the prompt again in that case).
///
/// Screen Recording is special: macOS exposes only "granted" vs "not granted"
/// (no distinction between "not yet asked" and "denied"), and changes to it
/// only take effect after an app restart. We surface this nuance in the UI by
/// showing an explicit caption beside the row.
@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
    }

    enum Kind: Hashable {
        case microphone
        case screenRecording
        case notifications
    }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var screenRecording: Status = .notDetermined
    @Published private(set) var notifications: Status = .notDetermined

    private let logger = Logger(subsystem: "com.gijirokutaker.app", category: "PermissionsManager")

    private init() {
        Task { await refresh() }
    }

    /// Polls the OS for current state. Cheap; call on view appear, on app
    /// activation, and after each request roundtrip so the UI keeps up with
    /// out-of-band changes (e.g. user toggled in System Settings).
    func refresh() async {
        microphone = mapAV(AVCaptureDevice.authorizationStatus(for: .audio))
        // CGPreflightScreenCaptureAccess returns false both for "not yet asked"
        // and "explicitly denied". We default to .notDetermined here and only
        // flip to .denied once the user has actually used the Request button —
        // that way the UI starts with a neutral state instead of accusing the
        // user of denying something they never saw.
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .granted
        } else if screenRecording == .granted {
            // Was granted before, no longer — fell back without revoking via UI.
            screenRecording = .denied
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = mapUN(settings.authorizationStatus)
    }

    func requestMicrophone() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = granted ? .granted : .denied
        case .authorized:
            microphone = .granted
        default:
            microphone = .denied
        }
    }

    /// Triggers the macOS Screen Recording prompt. If the user previously
    /// denied, this call is a silent no-op — the UI should fall back to
    /// "Open Settings".
    func requestScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            screenRecording = .granted
        } else {
            // Either the user just saw the prompt (response pending) or they
            // had denied before. We tentatively flag .denied; the next
            // refresh() call (triggered when the window regains focus) will
            // correct this if the user clicks Allow in the dialog.
            screenRecording = .denied
            logger.info("CGRequestScreenCaptureAccess returned false — prompt may have been shown or previously denied")
        }
    }

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notifications = granted ? .granted : .denied
        case .authorized, .provisional, .ephemeral:
            notifications = .granted
        default:
            notifications = .denied
        }
    }

    /// Opens System Settings to the privacy pane for the given permission.
    /// Used as the fallback when the OS won't re-show the prompt (denied).
    func openSystemSettings(for kind: Kind) {
        let urlString: String
        switch kind {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func mapAV(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func mapUN(_ status: UNAuthorizationStatus) -> Status {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

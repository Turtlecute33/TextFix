// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ServiceManagement

/// Run-at-login through SMAppService, which is the supported route on macOS 13 and later: the
/// system registers the bundle itself, the user can see and revoke it in System Settings > General
/// > Login Items, and there is no helper bundle, no launch agent plist and no elevation anywhere.
///
/// The service is the source of truth, so unlike the Windows agent there is nothing to persist in
/// config.json - the checkbox reads its state straight back from the system.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a sentence to show the user on failure. The usual failure is an
    /// app still sitting in ~/Downloads or on a mounted disk image, which macOS will not register.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    return nil
                case .requiresApproval:
                    // Registered, but switched off in System Settings. Registering again changes
                    // nothing; only the user can switch it back on, and only there.
                    SMAppService.openSystemSettingsLoginItems()
                    return "Turn TextFix on under System Settings > General > Login Items."
                default:
                    try SMAppService.mainApp.register()
                }
            } else {
                // A registration waiting for approval is removed too, or it would come back the
                // moment the user approved something else in that list.
                let status = SMAppService.mainApp.status
                guard status == .enabled || status == .requiresApproval else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.warn("Could not \(enabled ? "enable" : "disable") the login item: \(error.localizedDescription)")
            return enabled
                ? "macOS would not add TextFix to your login items. Move TextFix.app into your Applications folder and try again."
                : "macOS would not remove TextFix from your login items."
        }
    }
}

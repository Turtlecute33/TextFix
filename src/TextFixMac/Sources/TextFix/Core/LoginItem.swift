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
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
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

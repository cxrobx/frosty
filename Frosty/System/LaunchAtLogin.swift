import ServiceManagement

/// Abstracted so tests never register the test runner as a login item.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// macOS owns this preference. Read its current status rather than saving a
/// second copy that could disagree with changes made in System Settings.
final class LaunchAtLogin {
    private let service: LoginItemService

    init(service: LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    var status: SMAppService.Status { service.status }

    func toggle() throws {
        switch service.status {
        case .enabled, .requiresApproval:
            // A pending registration can also be cancelled from Frosty's menu.
            try service.unregister()
        case .notRegistered, .notFound:
            try service.register()
        @unknown default:
            try service.register()
        }
    }
}

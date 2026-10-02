import ServiceManagement
import XCTest

final class LaunchAtLoginTests: XCTestCase {
    private final class Service: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var registrationStatus: SMAppService.Status = .enabled
        var error: Error?
        var registrations = 0
        var unregistrations = 0

        func register() throws {
            registrations += 1
            if let error { throw error }
            status = registrationStatus
        }

        func unregister() throws {
            unregistrations += 1
            if let error { throw error }
            status = .notRegistered
        }
    }

    func testEnablingThenDisablingRegistersAndUnregisters() throws {
        let service = Service()
        let setting = LaunchAtLogin(service: service)
        XCTAssertEqual(service.registrations, 0, "Creating the setting must not enable it")
        try setting.toggle()
        XCTAssertEqual(setting.status, .enabled)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.unregistrations, 0)
        try setting.toggle()
        XCTAssertEqual(setting.status, .notRegistered)
        XCTAssertEqual(service.unregistrations, 1)
    }

    func testApprovalRequiredIsVisibleAndCanBeCancelled() throws {
        let service = Service()
        service.registrationStatus = .requiresApproval
        let setting = LaunchAtLogin(service: service)
        try setting.toggle()
        XCTAssertEqual(setting.status, .requiresApproval)
        try setting.toggle()
        XCTAssertEqual(setting.status, .notRegistered)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.unregistrations, 1)
    }

    func testChangesInSystemSettingsAreReadOnTheNextAccessAndToggle() throws {
        let service = Service()
        let setting = LaunchAtLogin(service: service)
        service.status = .enabled
        XCTAssertEqual(setting.status, .enabled)
        try setting.toggle()
        XCTAssertEqual(service.unregistrations, 1)
        service.status = .requiresApproval
        XCTAssertEqual(setting.status, .requiresApproval)
        try setting.toggle()
        XCTAssertEqual(service.unregistrations, 2)
        XCTAssertEqual(service.registrations, 0)
    }

    func testUnavailableRegistrationCanBeRetried() throws {
        let service = Service()
        service.status = .notFound
        let setting = LaunchAtLogin(service: service)
        try setting.toggle()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(setting.status, .enabled)
    }

    func testRegistrationFailureIsReportedWithoutClaimingItIsEnabled() {
        let service = Service()
        service.error = NSError(domain: "LoginItemTest", code: 1)
        let setting = LaunchAtLogin(service: service)
        XCTAssertThrowsError(try setting.toggle())
        XCTAssertEqual(setting.status, .notRegistered)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testUnregistrationFailureIsReportedWithoutClaimingItIsDisabled() {
        let service = Service()
        service.status = .enabled
        service.error = NSError(domain: "LoginItemTest", code: 1)
        let setting = LaunchAtLogin(service: service)
        XCTAssertThrowsError(try setting.toggle())
        XCTAssertEqual(setting.status, .enabled)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertEqual(service.registrations, 0)
    }
}

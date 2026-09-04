import Foundation
import XCTest
@testable import LibrarianAppSupport

final class HuggingFaceModelSetupTests: XCTestCase {
    func testApplicationSupportAndModelsShareOneFoundationResolvedTree() {
        let support = AppModelSetup.applicationSupportURL()
        let models = AppModelSetup.modelsURL()

        XCTAssertEqual(support.lastPathComponent, "PrivateLibrarian")
        XCTAssertEqual(models, support.appendingPathComponent("Models", isDirectory: true))

        // Regression: when called from App Sandbox, HOME already refers to the
        // container home. Re-appending Library/Containers/... produced a
        // nested bogus container tree and made completed installs invisible to
        // the model runtime.
        XCTAssertFalse(
            support.path.contains(
                "Library/Containers/com.tejas.private-librarian/Data/Library/Containers/"),
            "Application Support must come from Foundation, not from rebuilding a container path under HOME")
    }

    func testCheckoutCanResolvePackagedSetupHelperContract() {
        let script = AppModelSetup.setupScriptURL()
        XCTAssertNotNil(script)
        XCTAssertEqual(script?.lastPathComponent, "setup_models.sh")
        if let script {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        }
    }

    func testBlankHuggingFaceTokenIsRejectedBeforeKeychainMutation() {
        XCTAssertThrowsError(try HuggingFaceTokenStore.save("   \n")) { error in
            XCTAssertEqual(error as? HuggingFaceTokenStore.TokenError, .emptyToken)
        }
    }

    func testInstallerStageProtocolParsesOnlyWellFormedRecords() {
        XCTAssertEqual(
            AppModelSetup.progress(from: "__LIBRARIAN_SETUP_STAGE__|models|Downloading and verifying models…"),
            ModelSetupProgress(phase: "models", message: "Downloading and verifying models…"))
        XCTAssertNil(AppModelSetup.progress(from: "pip install something"))
        XCTAssertNil(AppModelSetup.progress(from: "__LIBRARIAN_SETUP_STAGE__|models|   "))
        XCTAssertNil(AppModelSetup.progress(from: "__LIBRARIAN_SETUP_STAGE__||missing phase"))
    }

    func testSetupOperationCanBeCancelledBeforeLaunch() {
        let operation = ModelSetupOperation()
        XCTAssertFalse(operation.isCancellationRequested)
        operation.cancel()
        XCTAssertTrue(operation.isCancellationRequested)
    }
}

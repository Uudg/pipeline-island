import Foundation
import XCTest
@testable import PipelineIsland

final class PipelineURLTests: XCTestCase {
    @MainActor
    func testPipelinePathUsesBrowserHostWhenAPIHostDiffers() throws {
        let suiteName = "PipelineURLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://gitlab-lan.casalicea.com", forKey: "gitlab.host")
        defaults.set("gitlab.casalicea.com", forKey: "gitlab.webHost")
        let preferences = Preferences(defaults: defaults)

        let pipeline = Pipeline(
            iid: "714",
            path: "/darklabs/homelab/-/pipelines/714",
            status: .success,
            projectPath: "darklabs/homelab"
        )

        let url = try XCTUnwrap(pipeline.webURL(host: preferences.webHost))
        XCTAssertEqual(
            url.absoluteString,
            "https://gitlab.casalicea.com/darklabs/homelab/-/pipelines/714"
        )
    }
}

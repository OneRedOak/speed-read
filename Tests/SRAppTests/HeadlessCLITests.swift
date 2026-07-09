import Testing
@testable import sr

@Suite @MainActor struct HeadlessCLITests {
    @Test func noArgumentsLaunchesGUI() {
        #expect(HeadlessCLI.Mode(arguments: ["sr"]) == nil)
    }

    @Test func parsesPrivacyAndCostFlags() {
        let mode = HeadlessCLI.Mode(arguments: [
            "sr", "--speak", "article.md", "--local", "--override-cost-controls",
        ])
        guard case .speak(let source, let forceLocal, let overrideCostControls) = mode else {
            Issue.record("expected speak mode")
            return
        }
        #expect(source == "article.md")
        #expect(forceLocal)
        #expect(overrideCostControls)
    }

    @Test func missingSpeakOperandIsUsageError() {
        let mode = HeadlessCLI.Mode(arguments: ["sr", "--speak", "--local"])
        guard case .usage(let error) = mode else {
            Issue.record("expected usage error")
            return
        }
        #expect(error?.contains("requires a file path") == true)
    }

    @Test func unknownArgumentsDoNotLaunchGUI() {
        let mode = HeadlessCLI.Mode(arguments: ["sr", "--unknown"])
        guard case .usage(let error) = mode else {
            Issue.record("expected usage error")
            return
        }
        #expect(error?.contains("unrecognized arguments") == true)
    }
}

import Testing
@testable import sr

@Suite @MainActor struct CLIValidationTests {
    @Test(arguments: [
        ["--speak", "article.md", "--locla"],
        ["--speak-clipboard", "--unknown"],
        ["--speak", "article.md", "extra.md"],
        ["--speak", "article.md", "--speak-clipboard"],
        ["--speak", "article.md", "--speak", "other.md"],
        ["--install-kokoro", "--speak-clipboard"],
        ["--install-kokoro", "--local"],
        ["--local"],
    ])
    func rejectsAmbiguousOrUnknownArguments(_ args: [String]) {
        guard case .usage(let error) = HeadlessCLI.Mode(arguments: ["sr"] + args) else {
            Issue.record("unsafe arguments accepted: \(args)")
            return
        }
        #expect(error != nil)
    }

    @Test(arguments: [["--speak", "--help"], ["--help", "--speak"], ["--unknown", "-h"]])
    func helpDoesNotRequireACompleteCommand(_ args: [String]) {
        guard case .usage(let error) = HeadlessCLI.Mode(arguments: ["sr"] + args) else {
            Issue.record("help attempted to execute a command")
            return
        }
        #expect(error == nil)
    }

    @Test func acceptsFlagsBeforeCommandAndStdin() {
        guard case .speak(let source, let local, let override) = HeadlessCLI.Mode(
            arguments: ["sr", "--local", "--speak", "-", "--override-cost-controls"]) else {
            Issue.record("valid stdin invocation rejected")
            return
        }
        #expect(source == "-")
        #expect(local)
        #expect(override)
    }
}

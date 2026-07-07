import Foundation

/// Entry point: headless CLI modes when invoked with flags, GUI app
/// otherwise. The CLI modes exist for acceptance testing and are the seed
/// of the Phase 4 `sr` CLI (A-1).
@main
enum SRMain {
    @MainActor
    static func main() async {
        if let mode = HeadlessCLI.Mode(arguments: CommandLine.arguments) {
            let code = await HeadlessCLI.run(mode)
            exit(code)
        }
        SRApp.main()
    }
}

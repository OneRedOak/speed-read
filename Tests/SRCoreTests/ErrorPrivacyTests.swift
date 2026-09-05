import Testing
@testable import SRCore

@Suite struct ErrorPrivacyTests {
    @Test func providerPayloadsNeverEnterLogCategories() {
        #expect(TTSError.http(status: 503, body: "secret text\nforged log").logCategory == "http_503")
        #expect(TTSError.network(underlying: "https://example.test/private").logCategory == "network")
        #expect(TTSError.invalidAudio(historyItemID: "secret-id", billedCharacters: 42).logCategory == "invalid_audio")
        #expect(TTSError.missingAPIKey.logCategory == "missing_api_key")
        #expect(TTSError.cancelled.logCategory == "cancelled")
        #expect(TTSError.budgetExceeded.logCategory == "budget_exceeded")
    }
}

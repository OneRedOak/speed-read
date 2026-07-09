public enum PlaybackCompletionPolicy {
    public static func canFinish(
        totalSentences: Int,
        appendedSentences: Int,
        pendingDecodes: Int,
        pendingRenders: Int,
        scheduledBuffers: Int
    ) -> Bool {
        totalSentences > 0
            && appendedSentences >= totalSentences
            && pendingDecodes == 0
            && pendingRenders == 0
            && scheduledBuffers == 0
    }
}

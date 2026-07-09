import Foundation

/// Provider plan shared by the GUI and CLI. Keeping this decision in SRCore
/// makes the Local-Only master switch impossible to bypass accidentally.
public enum BackendRoutePlan: Equatable, Sendable {
    case localOnly
    case cloudOnly
    case cloudWithLocalFallback
    case localUnavailable
}

public enum BackendRouting {
    public static func plan(
        mode: SettingsStore.BackendMode,
        forceLocal: Bool,
        localAvailable: Bool,
        hasCloudCredential: Bool
    ) -> BackendRoutePlan {
        if forceLocal || mode == .local {
            return localAvailable ? .localOnly : .localUnavailable
        }

        switch mode {
        case .local:
            return localAvailable ? .localOnly : .localUnavailable
        case .cloud:
            return .cloudOnly
        case .auto:
            if !hasCloudCredential, localAvailable {
                return .localOnly
            }
            return localAvailable ? .cloudWithLocalFallback : .cloudOnly
        }
    }
}

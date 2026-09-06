public enum AccountLoginMethod: Equatable {
    case chatGPT
    case codexCLI
    case unavailable
}

public struct ClientAvailability: Equatable {
    public let hasChatGPT: Bool
    public let hasCodexCLI: Bool

    public init(hasChatGPT: Bool, hasCodexCLI: Bool) {
        self.hasChatGPT = hasChatGPT
        self.hasCodexCLI = hasCodexCLI
    }

    public var accountLoginMethod: AccountLoginMethod {
        if hasChatGPT { return .chatGPT }
        if hasCodexCLI { return .codexCLI }
        return .unavailable
    }

    public var canAddAccount: Bool { accountLoginMethod != .unavailable }
}

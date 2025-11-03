import Foundation

/// Chat session state - matches desktop implementation
enum ChatState: String, Codable {
    case idle = "idle"
    case thinking = "thinking"
    case streaming = "streaming"
    case waitingForUserInput = "waitingForUserInput"
    case compacting = "compacting"
    case loadingConversation = "loadingConversation"
    
    /// Human-readable description for UI
    var displayText: String {
        switch self {
        case .idle:
            return "Ready"
        case .thinking:
            return "Thinking..."
        case .streaming:
            return "Responding..."
        case .waitingForUserInput:
            return "Waiting for approval"
        case .compacting:
            return "Compacting history..."
        case .loadingConversation:
            return "Loading..."
        }
    }
    
    /// Icon for UI display
    var icon: String {
        switch self {
        case .idle:
            return "checkmark.circle.fill"
        case .thinking:
            return "brain"
        case .streaming:
            return "arrow.down.circle"
        case .waitingForUserInput:
            return "hand.raised.fill"
        case .compacting:
            return "arrow.3.trianglepath"
        case .loadingConversation:
            return "arrow.clockwise"
        }
    }
    
    /// Whether this state indicates the session is actively processing
    var isProcessing: Bool {
        switch self {
        case .thinking, .streaming, .compacting, .loadingConversation:
            return true
        case .idle, .waitingForUserInput:
            return false
        }
    }
    
    /// Whether this state indicates waiting for user action
    var isWaitingForUser: Bool {
        return self == .waitingForUserInput
    }
    
    /// Whether this state indicates the session is complete/idle
    var isIdle: Bool {
        return self == .idle
    }
}

/// Helper to determine chat state from messages
extension ChatState {
    /// Determine state from current messages and tool calls
    static func from(messages: [Message], activeToolCalls: [String: ToolCallWithTiming]) -> ChatState {
        guard let lastMessage = messages.last else {
            return .idle
        }
        
        // Check for pending tool confirmation requests
        let hasPendingToolConfirmation = lastMessage.content.contains {
            if case .toolConfirmationRequest = $0 { return true }
            return false
        }
        
        if hasPendingToolConfirmation {
            return .waitingForUserInput
        }
        
        // Check for compacting notification
        let hasCompactingNotification = lastMessage.content.contains {
            if case .conversationCompacted = $0 { return true }
            return false
        }
        
        if hasCompactingNotification {
            return .compacting
        }
        
        // If there are active tool calls, we're thinking (waiting for tool results)
        if !activeToolCalls.isEmpty {
            return .thinking
        }
        
        // Check if last message is ONLY a tool response (no actual user text)
        let hasOnlyToolResponse = lastMessage.content.allSatisfy { content in
            if case .toolResponse = content { return true }
            return false
        }
        
        // If last message is only tool responses and no active tool calls,
        // the session is likely waiting for the assistant to process the results
        // This is still "thinking" state
        if hasOnlyToolResponse {
            return .thinking
        }
        
        // Check for thinking state (last message from user with actual content)
        if lastMessage.role == .user {
            return .thinking
        }
        
        // Otherwise idle
        return .idle
    }
}

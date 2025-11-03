//
//  SessionStateTracker.swift
//  Goose
//
//  Tracks active session states across the app for UI indicators
//

import Foundation
import Combine

/// Shared tracker for session states across the app
class SessionStateTracker: ObservableObject {
    static let shared = SessionStateTracker()
    
    /// Map of session ID to current chat state
    @Published private(set) var sessionStates: [String: ChatState] = [:]
    
    private init() {}
    
    /// Update the state for a specific session
    func updateState(sessionId: String, state: ChatState) {
        DispatchQueue.main.async {
            self.sessionStates[sessionId] = state
        }
    }
    
    /// Get the state for a specific session
    func getState(for sessionId: String) -> ChatState? {
        return sessionStates[sessionId]
    }
    
    /// Check if a session is actively processing
    func isProcessing(sessionId: String) -> Bool {
        return sessionStates[sessionId]?.isProcessing ?? false
    }
    
    /// Check if a session is waiting for user input
    func isWaitingForUser(sessionId: String) -> Bool {
        return sessionStates[sessionId]?.isWaitingForUser ?? false
    }
    
    /// Clear state for a session (e.g., when closed)
    func clearState(for sessionId: String) {
        DispatchQueue.main.async {
            self.sessionStates.removeValue(forKey: sessionId)
        }
    }
}

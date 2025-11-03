# ChatState Implementation - Next Steps

## Current Status
✅ ChatState enum created with all states
✅ chatState variable added to ChatView  
✅ Build succeeds with ChatState.swift in project

## What Needs to be Added

### 1. Helper Function to Update State
Add this function to ChatView after `stopStreaming()`:

```swift
/// Update chat state based on current messages and tool calls
private func updateChatState() {
    let newState = ChatState.from(messages: messages, activeToolCalls: activeToolCalls)
    if chatState != newState {
        let oldState = chatState
        chatState = newState
        print("🔄 Chat state changed: \(oldState.displayText) → \(newState.displayText)")
        
        // Send notification when session becomes idle or waiting for user
        if newState.isIdle || newState.isWaitingForUser {
            sendStateChangeNotification(state: newState)
        }
    }
}
```

### 2. Call updateChatState() at Key Points

**In `handleSSEEvent()` - after processing message:**
```swift
case .message(let messageEvent):
    // ... existing code ...
    
    // Update chat state after processing message content
    DispatchQueue.main.async {
        self.updateChatState()
    }
```

**In `handleSSEEvent()` - in .finish case:**
```swift
case .finish(let finishEvent):
    // ... existing code ...
    activeToolCalls.removeAll()
    
    // Update state now that stream is finished
    updateChatState()
```

**In `sendMessage()`:**
```swift
private func sendMessage() {
    // ... existing code ...
    messages.append(userMessage)
    inputText = ""
    isLoading = true
    
    // Update state - we're now thinking/processing
    chatState = .thinking
```

**In `loadSession()` - after rebuild:**
```swift
// Rebuild tool call state
rebuildToolCallState(from: sessionMessages)

// Update chat state based on loaded messages
updateChatState()
```

**In `startPollingForUpdates()` - after detecting changes:**
```swift
messages = newMessages
rebuildToolCallState(from: newMessages)

// Update state after polling detects changes
updateChatState()
```

### 3. Notification Function
Add this function to send system notifications:

```swift
/// Send system notification when session state changes
private func sendStateChangeNotification(state: ChatState) {
    guard let sessionId = currentSessionId else { return }
    
    let content = UNMutableNotificationContent()
    
    if state.isIdle {
        content.title = "Session Complete"
        content.body = "Session \(sessionId.prefix(8))... is ready"
        content.sound = .default
    } else if state.isWaitingForUser {
        content.title = "Approval Needed"
        content.body = "Session \(sessionId.prefix(8))... needs your confirmation"
        content.sound = .default
    }
    
    let request = UNNotificationRequest(
        identifier: "session-\(sessionId)-\(state.rawValue)",
        content: content,
        trigger: nil  // Immediate
    )
    
    UNUserNotificationCenter.current().add(request) { error in
        if let error = error {
            print("⚠️ Failed to send notification: \(error)")
        } else {
            print("✅ Sent notification for state: \(state.displayText)")
        }
    }
}
```

### 4. Request Notification Permission
Add to `onAppear` in ChatView:

```swift
.onAppear {
    // Request notification permission
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if granted {
            print("✅ Notification permission granted")
        } else if let error = error {
            print("⚠️ Notification permission error: \(error)")
        }
    }
    
    // ... rest of onAppear code ...
}
```

### 5. Using ChatState for Following Sessions

Check `chatState.isProcessing` to decide whether to poll:

```swift
/// Check if session should be followed/polled based on state
private func shouldFollowSession() -> Bool {
    return chatState.isProcessing || chatState.isWaitingForUser
}
```

Then use in sidebar or session list to show which sessions are active.

## Testing Points

1. Send a message → state should go to .thinking
2. Receive response → state should go to .idle
3. Tool confirmation needed → state should go to .waitingForUserInput  
4. Load a session with pending response → should detect and start polling
5. Get notification when session finishes

## Benefits

- **Know when sessions are done** - .idle state
- **Know when user action needed** - .waitingForUserInput state  
- **Follow active sessions** - .isProcessing property
- **Get notifications** - when state changes to idle/waiting
- **Better polling logic** - only poll when not idle
- **UI indicators** - show state icon/text in session list

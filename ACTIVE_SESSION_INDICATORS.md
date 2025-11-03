# Active Session Indicators - Implementation Plan

## ✅ Completed
1. Created `SessionStateTracker.swift` - shared state tracker
2. Updated `ChatView.swift` to broadcast state changes
3. Added notification permission request code structure

## 🔨 TODO - Add State Tracker to Xcode Project
1. Open Xcode
2. Right-click on Goose folder
3. Add `SessionStateTracker.swift` to project

## 🔨 TODO - Update ChatView to Broadcast State
Add these lines to `updateChatState()` in ChatView.swift:

```swift
private func updateChatState() {
    let newState = ChatState.from(messages: messages, activeToolCalls: activeToolCalls)
    if chatState != newState {
        let oldState = chatState
        chatState = newState
        print("🔄 Chat state changed: \(oldState.displayText) → \(newState.displayText)")
        
        // BROADCAST STATE TO TRACKER
        if let sessionId = currentSessionId {
            stateTracker.updateState(sessionId: sessionId, state: newState)
        }
        
        // Send notification when session becomes idle or waiting for user
        if newState.isIdle || newState.isWaitingForUser {
            sendStateChangeNotification(state: newState)
        }
    }
}
```

## 🔨 TODO - Request Notification Permissions
Add to `ChatView.onAppear`:

```swift
.onAppear {
    // Request notification permission
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        if granted {
            print("✅ Notification permission granted")
        } else if let error = error {
            print("⚠️ Notification permission error: \(error)")
        }
    }
    
    // ... rest of onAppear code
}
```

## 🔨 TODO - Add Visual Indicators to SidebarView

Add to SidebarView struct:
```swift
@StateObject private var stateTracker = SessionStateTracker.shared
```

In session row rendering, add pulsing indicator:
```swift
HStack {
    // ... existing content
    
    // Show indicator if session is processing
    if stateTracker.isProcessing(sessionId: session.id) {
        Circle()
            .fill(Color.blue)
            .frame(width: 8, height: 8)
            .modifier(PulseModifier())
    }
}
```

Add pulse modifier:
```swift
struct PulseModifier: ViewModifier {
    @State private var isPulsing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(
                Animation.easeInOut(duration: 1.0)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}
```

## 🔨 TODO - Add Visual Indicators to NodeMatrix

Add to NodeMatrix struct:
```swift
@StateObject private var stateTracker = SessionStateTracker.shared
```

In node rendering, add pulsing ring:
```swift
ZStack {
    // Existing node circle
    Circle()
        .fill(nodeColor)
        .frame(width: size, height: size)
    
    // Add pulsing ring if processing
    if stateTracker.isProcessing(sessionId: session.id) {
        Circle()
            .stroke(Color.blue, lineWidth: 2)
            .frame(width: size * 1.5, height: size * 1.5)
            .modifier(PulseModifier())
    }
}
```

## Testing Notifications

### Option 1: Background App
1. Start a session with a long-running task
2. Press home button to background the app
3. When task completes, you should get a notification

### Option 2: Simulator
1. In Simulator: Device → Trigger iCloud Sync (this helps with notifications)
2. Check notification center after state changes

### Option 3: Console Logs
Watch for these logs:
- `🔄 Chat state changed: <old> → <new>`
- `✅ Sent notification for state: <state>`
- `⚠️ Failed to send notification: <error>`

### Debug Notifications
Add to `sendStateChangeNotification`:
```swift
// At the start
print("📬 Attempting to send notification for session \(sessionId) in state \(state)")

// Check permission
UNUserNotificationCenter.current().getNotificationSettings { settings in
    print("📬 Notification settings: \(settings.authorizationStatus.rawValue)")
}
```

## Expected Behavior

**Session List:**
- Blue pulsing dot next to sessions that are actively processing
- Dot disappears when session becomes idle

**Node Graph:**
- Blue pulsing ring around nodes that are actively processing
- Subtle, non-intrusive animation (1 second cycle)
- Ring disappears when session becomes idle

**Notifications:**
- "Session Complete" when session reaches idle state
- "Approval Needed" when session is waiting for tool confirmation
- Only when app is in background or not focused on that session

# Session State Detection

## How Desktop Does It

Desktop uses an explicit state machine with `ChatState` enum:
- `Idle` - Session complete, ready for input
- `Thinking` - Processing user request
- `Streaming` - Receiving response
- `WaitingForUserInput` - Needs user confirmation (tool approval)
- `Compacting` - Compressing conversation history
- `LoadingConversation` - Loading existing session

## Key Detection Logic

**Stream is complete when:**
- Receive `Finish` SSE event

**Still waiting for user when:**
- Last message contains `toolConfirmationRequest` content type
- This indicates agent needs explicit approval to run a tool

**Otherwise:**
- Session is `Idle` (complete, ready for new input)

## iOS Implementation

Add similar state tracking:

1. **Add ChatState enum** similar to desktop
2. **Check message content types** not just roles:
   ```swift
   let hasPendingToolConfirmation = lastMessage?.content.contains {
       if case .toolConfirmationRequest = $0 { return true }
       return false
   } ?? false
   ```
3. **Track state transitions** during SSE streaming
4. **Expose state** for UI indicators and notifications

## Benefits

- Show session status in sidebar (✓ complete, ⏳ waiting, 🔄 processing)
- Send notifications when sessions finish
- Know when it's safe to resume a session
- Better polling logic (only poll when actually waiting)
- Align behavior with desktop client

## Current iOS State Detection

Currently uses heuristics:
- `lastMessage.role == .user` → waiting for response
- `!activeToolCalls.isEmpty` → processing tools
- Otherwise → assume complete

This works but misses the `toolConfirmationRequest` case where agent is explicitly waiting for approval.

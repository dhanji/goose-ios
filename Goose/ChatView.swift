import SwiftUI

struct ChatView: View {
    @Binding var showingSidebar: Bool
    let onBackToWelcome: () -> Void
    @StateObject private var apiService = GooseAPIService.shared
    @State private var messages: [Message] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var currentStreamTask: URLSessionDataTask?
    @State private var showingErrorDetails = false
    @State private var activeToolCalls: [String: ToolCallWithTiming] = [:]
    @State private var completedToolCalls: [String: CompletedToolCall] = [:]
    @State private var toolCallMessageMap: [String: String] = [:]
    @State private var currentSessionId: String?
    @State private var isSettingsPresented = false

    @FocusState private var isInputFocused: Bool

    // Session polling for live updates
    @State private var isPollingForUpdates = false
    @State private var pollingTask: Task<Void, Never>?

    // Voice features - shared with WelcomeView
    @ObservedObject var voiceManager: EnhancedVoiceManager

    // Memory management
    private let maxMessages = 50  // Limit messages to prevent memory issues
    private let maxToolCalls = 20  // Limit tool calls to prevent memory issues

    // Efficient scroll management
    @State private var scrollTimer: Timer?
    @State private var shouldAutoScroll = true
    @State private var scrollRefreshTrigger = UUID()  // Force scroll refresh
    @State private var lastScrollUpdate = Date()  // Throttle streaming scrolls
    @State private var isActivelyStreaming = false  // Track if we're currently receiving streaming content
    @State private var userIsScrolling = false  // Track manual scroll interactions
    @State private var lastContentHeight: CGFloat = 0  // Track content size changes

    var body: some View {
        ZStack(alignment: .top) {
            // Background color
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            // Main content that stops before input area
            VStack(spacing: 0) {
                // Messages scroll view with proper constraints
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    completedTasks: getCompletedTasksForMessage(message.id),
                                    sessionName: currentSessionId ?? "Current Session"
                                )
                                .id(message.id)

                                // Show ONLY active/in-progress tool calls (completed ones are in the pill)
                                ForEach(getToolCallsForMessage(message.id), id: \.self) {
                                    toolCallId in
                                    if let activeCall = activeToolCalls[toolCallId] {
                                        ToolCallProgressView(toolCall: activeCall.toolCall)
                                            .id("tool-\(toolCallId)")
                                    }
                                }
                            }

                            // Show "thinking" indicator if no active tool calls
                            if isLoading && activeToolCalls.isEmpty {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("goose is thinking...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .id("thinking-indicator")
                            } else if isPollingForUpdates {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("🔍 Checking for new messages...")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .id("polling-indicator")
                            }

                            // Add space at the bottom so the last message can scroll above the input area
                            // This is actual content space, not padding, so it scrolls with the messages
                            Spacer()
                                .frame(height: 180)
                        }
                        .padding(.horizontal)
                        .padding(.top, 70)  // Matches PR #1 with simpler nav bar
                    }
                    .refreshable {
                        await refreshCurrentSession()
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { _ in
                                // User is manually scrolling
                                if isLoading {
                                    userIsScrolling = true
                                    shouldAutoScroll = false
                                    print("📜 User started scrolling - auto-scroll disabled")
                                }
                            }
                            .onEnded { _ in
                                // User finished scrolling gesture
                                userIsScrolling = false
                                print("📜 User finished scrolling gesture")
                            }
                    )
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIApplication.willEnterForegroundNotification)
                    ) { _ in
                        // Only scroll when app comes to foreground, not on every update
                        if shouldAutoScroll {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: scrollRefreshTrigger) { _ in
                        // Force scroll when session is loaded
                        if shouldAutoScroll && !messages.isEmpty {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: messages.count) { _ in
                        // Only auto-scroll for new messages if we're actively loading/streaming
                        // This prevents jumping back to bottom when user scrolls up after streaming is done
                        if isLoading && shouldAutoScroll {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToBottom(proxy)
                            }
                        }
                    }
                }
            }

            // Gradient fade overlay to dim content above the input box
            VStack {
                Spacer()
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color(UIColor.systemBackground).opacity(0.7),
                        Color(UIColor.systemBackground),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .allowsHitTesting(false)
            }

            // Floating input area - using shared ChatInputView
            VStack {
                Spacer()

                ChatInputView(
                    text: $inputText,
                    isFocused: $isInputFocused,
                    showPlusButton: true,
                    isLoading: isLoading,
                    voiceManager: voiceManager,
                    onSubmit: {
                        sendMessage()
                    },
                    onStop: {
                        stopStreaming()
                    }
                )
                .padding(.bottom, 0)
            }

            // Custom navigation bar with background
            VStack(spacing: 0) {
                // Navigation bar - PR #1 style with back button
                HStack(spacing: 8) {
                    // Back button (navigates to welcome)
                    Button(action: {
                        onBackToWelcome()
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    // Sidebar button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showingSidebar.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 22))
                            .foregroundColor(.primary)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)

                    // Session name
                    Text(currentSessionId != nil ? "Session" : "New Session")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)  // Slightly lower than before
                .padding(.bottom, 24)
                .background(
                    Color(UIColor.systemBackground)
                        .opacity(0.95)
                        .background(.regularMaterial)
                )
            }

            // Sidebar is now rendered by ContentView
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(ConfigurationHandler.shared)
        }
        .onChange(of: voiceManager.transcribedText) { newText in
            // Update input text with transcribed text in real-time
            if !newText.isEmpty && voiceManager.voiceMode != .normal {
                inputText = newText
            }
        }
        .onAppear {
            // Set up voice manager callback
            voiceManager.onSubmitMessage = { transcribedText in
                // Create the message and send it
                inputText = transcribedText
                sendMessage()
            }

            Task {
                await apiService.testConnection()
            }

            // Listen for initial message from WelcomeView
            NotificationCenter.default.addObserver(
                forName: Notification.Name("SendInitialMessage"),
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String {
                    inputText = message
                    sendMessage()
                }
            }

            // Listen for session load from WelcomeView
            NotificationCenter.default.addObserver(
                forName: Notification.Name("LoadSession"),
                object: nil,
                queue: .main
            ) { notification in
                if let sessionId = notification.userInfo?["sessionId"] as? String {
                    loadSession(sessionId)
                }
            }

            // Listen for message to be sent to specific session
            NotificationCenter.default.addObserver(
                forName: Notification.Name("SendMessageToSession"),
                object: nil,
                queue: .main
            ) { notification in
                if let message = notification.userInfo?["message"] as? String,
                   let sessionId = notification.userInfo?["sessionId"] as? String {
                    // Load the session first
                    loadSession(sessionId)
                    // Then set the input text and send
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        inputText = message
                        sendMessage()
                    }
                }
            }
        }
    }
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        var lastId: String?

        if let lastMessage = messages.last {
            let toolCallsForLastMessage = getToolCallsForMessage(lastMessage.id)
            if !toolCallsForLastMessage.isEmpty {
                lastId = "tool-\(toolCallsForLastMessage.last!)"
            } else {
                lastId = lastMessage.id
            }
        }

        if let scrollId = lastId {
            withAnimation(.easeOut(duration: 0.3)) {
                // Use .bottom to scroll all the way, the padding in the content should handle visibility
                proxy.scrollTo(scrollId, anchor: .bottom)
            }
        }
    }

    private func sendMessage() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty && !isLoading else { return }

        let userMessage = Message(role: .user, text: trimmedText)
        messages.append(userMessage)
        inputText = ""
        isLoading = true

        // Re-enable auto-scroll when user sends a new message
        shouldAutoScroll = true

        // Stop polling and switch to real-time streaming
        stopPollingForUpdates()

        startChatStream()
    }

    private func startChatStream() {
        Task {
            do {
                // Create session if we don't have one
                if currentSessionId == nil {
                    let (sessionId, initialMessages) = try await apiService.startAgent(
                        workingDir: "/tmp")
                    print("✅ SESSION CREATED: \(sessionId)")

                    // Load any initial messages from the session
                    if !initialMessages.isEmpty {
                        await MainActor.run {
                            messages = initialMessages
                        }
                    }

                    // Read provider and model from config
                    print("🔧 READING PROVIDER AND MODEL FROM CONFIG")
                    guard let provider = await apiService.readConfigValue(key: "GOOSE_PROVIDER"),
                        let model = await apiService.readConfigValue(key: "GOOSE_MODEL")
                    else {
                        throw APIError.noData
                    }

                    print("🔧 UPDATING PROVIDER TO \(provider) WITH MODEL \(model)")
                    try await apiService.updateProvider(
                        sessionId: sessionId, provider: provider, model: model)
                    print("✅ PROVIDER UPDATED FOR SESSION: \(sessionId)")

                    // Apply server-side prompts (desktop_prompt.md + recipe if present)
                    print("🔧 UPDATING AGENT FROM SESSION: \(sessionId)")
                    try await apiService.updateFromSession(sessionId: sessionId)
                    print("✅ AGENT UPDATED FROM SESSION: \(sessionId)")

                    // Load enabled extensions just like desktop does
                    print("🔧 LOADING ENABLED EXTENSIONS FOR SESSION: \(sessionId)")
                    try await apiService.loadEnabledExtensions(sessionId: sessionId)

                    currentSessionId = sessionId
                }

                guard let sessionId = currentSessionId else {
                    throw APIError.invalidResponse
                }

                currentStreamTask = await apiService.startChatStreamWithSSE(
                    messages: messages,
                    sessionId: sessionId,
                    onEvent: { event in
                        handleSSEEvent(event)
                    },
                    onComplete: {
                        isLoading = false
                        currentStreamTask = nil
                    },
                    onError: { error in
                        print("🚨 SSE Stream Error: \(error)")
                        
                        // For debugging, show more detail for HTTP errors
                        if case APIError.httpError(let code, let body) = error {
                            print("🚨 HTTP Error \(code) - Full response body:")
                            print(body)
                        }
                        
                        // Don't retry SSE - switch to polling mode instead
                        // This avoids duplicate work and handles network failures gracefully
                        currentStreamTask = nil
                        
                        print("🔄 SSE failed, switching to polling mode to check for response...")
                        
                        // Start polling to check if response completed server-side
                        if let pollingSessionId = currentSessionId {
                            startPollingForUpdates(sessionId: pollingSessionId)
                        } else {
                            // No session ID, can't poll - show error
                            isLoading = false
                            let errorMessage = Message(
                                role: .assistant,
                                text: "❌ Connection failed: \(error.localizedDescription)"
                            )
                            messages.append(errorMessage)
                        }
                    }
                )
            } catch {
                await MainActor.run {
                    isLoading = false
                    print("🚨 Session setup error: \(error)")

                    let errorMessage = Message(
                        role: .assistant,
                        text: "❌ Failed to initialize session: \(error.localizedDescription)"
                    )
                    messages.append(errorMessage)
                }
            }
        }
    }

    private func handleSSEEvent(_ event: SSEEvent) {
        // Only block events if we're explicitly switching sessions
        // Don't block normal streaming operation
        if currentStreamTask == nil {
            print("⚠️ Ignoring SSE event - stream was cancelled")
            return
        }

        switch event {
        case .message(let messageEvent):
            let incomingMessage = messageEvent.message

            // Track tool calls and responses
            for content in incomingMessage.content {
                switch content {
                case .toolRequest(let toolRequest):
                    activeToolCalls[toolRequest.id] = ToolCallWithTiming(
                        toolCall: toolRequest.toolCall,
                        startTime: Date()
                    )
                    toolCallMessageMap[toolRequest.id] = incomingMessage.id
                case .toolResponse(let toolResponse):
                    if let activeCall = activeToolCalls.removeValue(forKey: toolResponse.id) {
                        let duration = Date().timeIntervalSince(activeCall.startTime)
                        completedToolCalls[toolResponse.id] = CompletedToolCall(
                            toolCall: activeCall.toolCall,
                            result: toolResponse.toolResult,
                            duration: duration,
                            completedAt: Date()
                        )
                    }
                case .summarizationRequested(_):
                    // Handle summarization requests - just log for now
                    print("📝 Summarization requested for message: \(incomingMessage.id)")
                default:
                    break
                }
            }

            // Batch UI updates to reduce frequency
            DispatchQueue.main.async {
                // Double-check we still have an active session before updating UI
                guard self.currentSessionId != nil else {
                    print("⚠️ Ignoring UI update - session was cleared")
                    return
                }

                if let existingIndex = self.messages.firstIndex(where: {
                    $0.id == incomingMessage.id
                }) {
                    var updatedMessage = self.messages[existingIndex]

                    if let existingTextContent = updatedMessage.content.first(where: {
                        if case .text = $0 { return true } else { return false }
                    }),
                        let incomingTextContent = incomingMessage.content.first(where: {
                            if case .text = $0 { return true } else { return false }
                        })
                    {
                        if case .text(let existingText) = existingTextContent,
                            case .text(let incomingText) = incomingTextContent
                        {
                            let combinedText = existingText.text + incomingText.text
                            updatedMessage = Message(
                                id: incomingMessage.id, role: incomingMessage.role,
                                content: [MessageContent.text(TextContent(text: combinedText))],
                                created: incomingMessage.created, metadata: incomingMessage.metadata
                            )
                        }
                    }

                    self.messages[existingIndex] = updatedMessage
                    // Trigger scroll when message content is updated during streaming
                    // Throttle to avoid excessive scrolling during rapid updates
                    if self.shouldAutoScroll {
                        let now = Date()
                        if now.timeIntervalSince(self.lastScrollUpdate) > 0.1 {  // Throttle to 10 updates per second
                            self.lastScrollUpdate = now
                            self.scrollRefreshTrigger = UUID()
                        }
                    }
                } else {
                    self.messages.append(incomingMessage)
                    // Manage memory by limiting messages and tool calls
                    self.limitMessages()
                    self.limitToolCalls()
                }
            }

        case .error(let errorEvent):
            let errorMessage = Message(
                role: .assistant,
                text: "Error: \(errorEvent.error)"
            )
            messages.append(errorMessage)

        case .finish(let finishEvent):
            print("Stream finished: \(finishEvent.reason)")
            for (id, activeCall) in activeToolCalls {
                let duration = Date().timeIntervalSince(activeCall.startTime)
                completedToolCalls[id] = CompletedToolCall(
                    toolCall: activeCall.toolCall,
                    result: ToolResult(status: "timeout", value: nil, error: "Stream finished"),
                    duration: duration,
                    completedAt: Date()
                )
            }
            activeToolCalls.removeAll()

            // Force final scroll to bottom when streaming completes
            if shouldAutoScroll {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scrollRefreshTrigger = UUID()
                }
            }

            // Handle voice mode response - only speak if in full audio mode
            if voiceManager.voiceMode == .fullAudio,
                let lastMessage = messages.last,
                lastMessage.role == .assistant,
                let textContent = lastMessage.content.first(where: {
                    if case .text = $0 { return true } else { return false }
                }),
                case .text(let content) = textContent
            {
                print("🎤 Speaking response in full audio mode")
                voiceManager.speakResponse(content.text)
            }

        case .modelChange(let modelEvent):
            print("Model changed: \(modelEvent.model) (\(modelEvent.mode))")

        case .notification(_):
            // Just ignore notifications silently - they're too verbose for shell output
            break

        case .updateConversation(let updateEvent):
            // Replace the entire conversation with the compacted version
            DispatchQueue.main.async {
                print("📚 Updating conversation with \(updateEvent.conversation.count) messages")
                self.messages = updateEvent.conversation
                // Clear tool call tracking since we have a new conversation history
                self.activeToolCalls.removeAll()
                self.completedToolCalls.removeAll()
                self.toolCallMessageMap.removeAll()
                // Rebuild tool call state from the new messages
                self.rebuildToolCallState(from: updateEvent.conversation)
                // Trigger a UI refresh
                self.scrollRefreshTrigger = UUID()
            }

        case .ping:
            break
        }
    }

    private func stopStreaming() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
        isLoading = false
        stopPollingForUpdates()  // Also stop polling if any
    }

    // MARK: - Session Polling for Live Updates

    /// Check if we should poll for updates based on message state
    private func shouldPollForUpdates(_ messages: [Message]) -> Bool {
        guard let lastMessage = messages.last else {
            print("🔍 No messages, no polling")
            return false
        }

        // created timestamp - detect if it's in seconds or milliseconds
        // If > year 2100 in seconds (4102444800), it's probably milliseconds
        let createdTimestamp = lastMessage.created
        let createdDate: Date
        if createdTimestamp > 4_102_444_800 {
            // Likely milliseconds
            createdDate = Date(timeIntervalSince1970: TimeInterval(createdTimestamp) / 1000.0)
        } else {
            // Likely seconds
            createdDate = Date(timeIntervalSince1970: TimeInterval(createdTimestamp))
        }

        let age = Date().timeIntervalSince(createdDate)

        print("🔍 Last message role: \(lastMessage.role), age: \(Int(age))s")

        // Poll if last message is recent (< 2 minutes)
        // This catches both waiting-for-response and mid-response scenarios
        let shouldPoll = age < 120 && age > -60  // 2 minutes, but also check for future dates
        if shouldPoll {
            print("🔍 ✅ Will start polling (recent activity)")
        } else {
            print("🔍 ❌ Too old (\(Int(age))s), won't poll")
        }
        return shouldPoll
    }

    /// Start polling for new messages in resumed session
    private func startPollingForUpdates(sessionId: String) {
        stopPollingForUpdates()  // Cancel any existing polling

        print("📡 Starting polling for session: \(sessionId)")
        isPollingForUpdates = true

        // Store a hash of current messages for comparison
        let initialHash = messagesHash(messages)

        pollingTask = Task {
            var noChangeCount = 0
            var pollInterval: TimeInterval = 2.0  // Start at 2 seconds for faster detection
            let maxNoChangeChecks = 10  // 10 checks with no change = ~20 seconds
            var lastHash = initialHash

            while !Task.isCancelled && noChangeCount < maxNoChangeChecks {
                // Wait before next poll
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

                guard !Task.isCancelled else { break }

                do {
                    // Fetch latest messages from server
                    let (_, newMessages) = try await apiService.resumeAgent(sessionId: sessionId)
                    let newHash = messagesHash(newMessages)

                    await MainActor.run {
                        if newHash != lastHash {
                            // Content changed!
                            print("📡 Polling detected changes (hash: \(lastHash) -> \(newHash))")

                            // Update messages
                            messages = newMessages

                            // Rebuild tool call state from messages
                            rebuildToolCallState(from: newMessages)

                            noChangeCount = 0
                            lastHash = newHash
                            scrollRefreshTrigger = UUID()

                            // Reset poll interval when we find changes
                            pollInterval = 2.0
                        } else {
                            // No changes
                            noChangeCount += 1
                            print("📡 Poll check \(noChangeCount)/\(maxNoChangeChecks): no changes")

                            // Exponential backoff up to 5 seconds
                            if noChangeCount > 3 {
                                pollInterval = min(pollInterval * 1.3, 5.0)
                            }
                        }
                    }
                } catch {
                    // Check if it's a 404 - session might have been deleted
                    if case APIError.httpError(let code, let message) = error, code == 404 {
                        print(
                            "⚠️ Polling got 404 for session \(sessionId) - session no longer exists, stopping polling"
                        )
                        await MainActor.run {
                            isPollingForUpdates = false
                        }
                        break  // Stop polling completely
                    }

                    print("⚠️ Polling error for session \(sessionId): \(error)")
                    // Don't stop on other errors, but increment no-change count
                    noChangeCount += 1

                    // If we get too many errors, stop polling
                    if noChangeCount >= maxNoChangeChecks {
                        print("⚠️ Too many polling errors, stopping")
                        break
                    }
                }
            }

            // Polling finished
            await MainActor.run {
                isPollingForUpdates = false
                print(
                    "✅ Polling stopped after \(noChangeCount >= maxNoChangeChecks ? "timeout" : "cancellation")"
                )
            }
        }
    }

    /// Generate hash of messages for change detection
    private func messagesHash(_ messages: [Message]) -> String {
        // Create a string representation of key message properties
        let content = messages.map { msg in
            let contentStr = msg.content.map { c in
                switch c {
                case .text(let tc): return "t:\(tc.text)"
                case .toolRequest(let tr): return "treq:\(tr.id)"
                case .toolResponse(let tr): return "tres:\(tr.id):\(tr.toolResult.status)"
                case .summarizationRequested: return "sum"
                case .toolConfirmationRequest(let tcr): return "tconf:\(tcr.id)"
                case .conversationCompacted(let cc): return "compact:\(cc.msg)"
                }
            }.joined(separator: "|")
            return "\(msg.id):\(msg.role):\(contentStr)"
        }.joined(separator: ";")

        // Simple hash - just use count + first 100 chars
        let preview = String(content.prefix(100))
        return "\(messages.count):\(content.count):\(preview)"
    }

    /// Rebuild activeToolCalls and completedToolCalls from messages
    private func rebuildToolCallState(from messages: [Message]) {
        print("🔧 Rebuilding tool call state from \(messages.count) messages")

        // Clear existing state
        var newActiveToolCalls: [String: ToolCallWithTiming] = [:]
        var newCompletedToolCalls: [String: CompletedToolCall] = [:]
        var newToolCallMessageMap: [String: String] = [:]

        // Track which tool requests have responses
        var toolRequestIds = Set<String>()
        var toolResponseIds = Set<String>()

        // First pass: collect all IDs
        for message in messages {
            for content in message.content {
                switch content {
                case .toolRequest(let toolRequest):
                    toolRequestIds.insert(toolRequest.id)
                case .toolResponse(let toolResponse):
                    toolResponseIds.insert(toolResponse.id)
                default:
                    break
                }
            }
        }

        // Second pass: categorize as active or completed
        for message in messages {
            for content in message.content {
                switch content {
                case .toolRequest(let toolRequest):
                    newToolCallMessageMap[toolRequest.id] = message.id

                    if !toolResponseIds.contains(toolRequest.id) {
                        // No response yet - this is active
                        newActiveToolCalls[toolRequest.id] = ToolCallWithTiming(
                            toolCall: toolRequest.toolCall,
                            startTime: Date(
                                timeIntervalSince1970: TimeInterval(message.created) / 1000.0)
                        )
                    }

                case .toolResponse(let toolResponse):
                    // Find the corresponding request
                    if let requestMessage = messages.first(where: { msg in
                        msg.content.contains(where: { c in
                            if case .toolRequest(let tr) = c, tr.id == toolResponse.id {
                                return true
                            }
                            return false
                        })
                    }) {
                        // Find the tool call from request
                        if let requestContent = requestMessage.content.first(where: { c in
                            if case .toolRequest(let tr) = c, tr.id == toolResponse.id {
                                return true
                            }
                            return false
                        }),
                            case .toolRequest(let toolRequest) = requestContent
                        {

                            let startTime = Date(
                                timeIntervalSince1970: TimeInterval(requestMessage.created) / 1000.0
                            )
                            let endTime = Date(
                                timeIntervalSince1970: TimeInterval(message.created) / 1000.0)
                            let duration = endTime.timeIntervalSince(startTime)

                            newCompletedToolCalls[toolResponse.id] = CompletedToolCall(
                                toolCall: toolRequest.toolCall,
                                result: toolResponse.toolResult,
                                duration: duration,
                                completedAt: endTime
                            )
                        }
                    }

                default:
                    break
                }
            }
        }

        // Update state
        activeToolCalls = newActiveToolCalls
        completedToolCalls = newCompletedToolCalls
        toolCallMessageMap = newToolCallMessageMap

        print(
            "🔧 Rebuilt: \(newActiveToolCalls.count) active, \(newCompletedToolCalls.count) completed"
        )
    }

    /// Stop polling for updates
    private func stopPollingForUpdates() {
        if let task = pollingTask {
            task.cancel()
            pollingTask = nil
            isPollingForUpdates = false
            print("🛑 Stopped polling")
        }
    }

    private func getToolCallsForMessage(_ messageId: String) -> [String] {
        return toolCallMessageMap.compactMap { (toolCallId, mappedMessageId) in
            mappedMessageId == messageId ? toolCallId : nil
        }.sorted()
    }

    private func getCompletedTasksForMessage(_ messageId: String) -> [CompletedToolCall] {
        let toolCallIds = getToolCallsForMessage(messageId)
        return toolCallIds.compactMap { completedToolCalls[$0] }
    }

    private func limitMessages() {
        guard messages.count > maxMessages else { return }

        // Keep only the most recent messages, but always keep the first message (usually system prompt)
        let messagesToRemove = messages.count - maxMessages
        let startIndex = messages.count > 1 ? 1 : 0  // Keep first message if exists

        let removedMessages = Array(messages[startIndex..<startIndex + messagesToRemove])
        messages.removeSubrange(startIndex..<startIndex + messagesToRemove)

        // Clean up tool call mappings for removed messages
        for removedMessage in removedMessages {
            toolCallMessageMap = toolCallMessageMap.filter { $0.value != removedMessage.id }
        }

        print("🧹 Memory cleanup: removed \(messagesToRemove) old messages")
    }

    private func limitToolCalls() {
        // Limit completed tool calls to prevent memory accumulation
        guard completedToolCalls.count > maxToolCalls else { return }

        let toolCallsToRemove = completedToolCalls.count - maxToolCalls
        let sortedCalls = completedToolCalls.sorted { $0.value.completedAt < $1.value.completedAt }

        for i in 0..<toolCallsToRemove {
            let toolCallId = sortedCalls[i].key
            completedToolCalls.removeValue(forKey: toolCallId)
            toolCallMessageMap.removeValue(forKey: toolCallId)
        }

        print("🧹 Tool call cleanup: removed \(toolCallsToRemove) old tool calls")
    }

    func loadSession(_ sessionId: String) {
        // CRITICAL: Cancel any existing stream before switching sessions
        if let currentTask = currentStreamTask {
            print("🛑 Cancelling existing stream before session switch")
            currentTask.cancel()
            currentStreamTask = nil
        }

        // Handle trial mode sessions differently
        if apiService.isTrialMode && sessionId.starts(with: "trial-demo-") {
            Task {
                await MainActor.run {
                    // Clear ALL old state first
                    self.stopStreaming()
                    activeToolCalls.removeAll()
                    completedToolCalls.removeAll()
                    toolCallMessageMap.removeAll()
                    currentSessionId = nil  // Trial sessions don't have real session IDs

                    // Load the mock messages
                    messages = apiService.getMockMessages(for: sessionId)

                    // Add a trial mode notice at the beginning
                    let trialNotice = Message(
                        role: .assistant,
                        text:
                            "🔔 **Trial Mode**: This is a trial session. To access persistent sessions and full functionality, connect to your personal goose agent."
                    )
                    messages.insert(trialNotice, at: 0)

                    // Force scroll to bottom after loading
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        shouldAutoScroll = true
                        scrollRefreshTrigger = UUID()
                    }
                }
            }
            return
        }

        Task {
            do {
                // Resume the session
                let (resumedSessionId, sessionMessages) = try await apiService.resumeAgent(
                    sessionId: sessionId)
                print("✅ SESSION RESUMED: \(resumedSessionId)")
                print("📝 Loaded \(sessionMessages.count) messages")

                // Read provider and model from config (same as new session)
                print("🔧 READING PROVIDER AND MODEL FROM CONFIG")
                guard let provider = await apiService.readConfigValue(key: "GOOSE_PROVIDER"),
                    let model = await apiService.readConfigValue(key: "GOOSE_MODEL")
                else {
                    throw APIError.noData
                }

                print("🔧 UPDATING PROVIDER TO \(provider) WITH MODEL \(model)")
                try await apiService.updateProvider(
                    sessionId: resumedSessionId, provider: provider, model: model)
                print("✅ PROVIDER UPDATED FOR RESUMED SESSION: \(resumedSessionId)")

                // Apply server-side prompts (desktop_prompt.md + recipe if present)
                print("🔧 UPDATING AGENT FROM SESSION: \(resumedSessionId)")
                try await apiService.updateFromSession(sessionId: resumedSessionId)
                print("✅ AGENT UPDATED FROM SESSION: \(resumedSessionId)")

                // Load enabled extensions just like desktop does (same as new session)
                print("🔧 LOADING ENABLED EXTENSIONS FOR RESUMED SESSION: \(resumedSessionId)")
                try await apiService.loadEnabledExtensions(sessionId: resumedSessionId)

                // Update all state on main thread at once
                await MainActor.run {
                    // CRITICAL: Clear ALL old state first to prevent event contamination
                    self.stopStreaming()  // This clears currentStreamTask and isLoading
                    activeToolCalls.removeAll()
                    completedToolCalls.removeAll()
                    toolCallMessageMap.removeAll()

                    // Set new state with forced UI refresh
                    currentSessionId = resumedSessionId

                    // Force UI refresh by clearing and setting messages
                    messages.removeAll()
                    messages = sessionMessages

                    print("📊 Messages array now has \(messages.count) messages")
                    print("📊 First message ID: \(messages.first?.id ?? "none")")
                    print("📊 Last message ID: \(messages.last?.id ?? "none")")

                    // Force scroll to bottom after loading
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        shouldAutoScroll = true
                        scrollRefreshTrigger = UUID()  // Force UI refresh and scroll
                    }

                    // Check if we should start polling for live updates
                    if shouldPollForUpdates(sessionMessages) {
                        print("🔄 Session appears to be waiting for response, starting polling...")
                        startPollingForUpdates(sessionId: resumedSessionId)
                    }
                }
            } catch {
                print("🚨 Failed to load session: \(error)")
                await MainActor.run {
                    let errorMessage = Message(
                        role: .assistant,
                        text: "❌ Failed to load session: \(error.localizedDescription)"
                    )
                    messages.append(errorMessage)
                }
            }
        }
    }

    func createNewSession() {
        // CRITICAL: Cancel any existing stream before creating new session
        if let currentTask = currentStreamTask {
            print("🛑 Cancelling existing stream before creating new session")
            currentTask.cancel()
            currentStreamTask = nil
        }

        // Clear all state for a fresh session
        messages.removeAll()
        activeToolCalls.removeAll()
        completedToolCalls.removeAll()
        toolCallMessageMap.removeAll()
        currentSessionId = nil
        isLoading = false

        print("🆕 Created new session - cleared all state")
    }
    
    /// Refresh the current session (for pull-to-refresh)
    private func refreshCurrentSession() async {
        guard let sessionId = currentSessionId else {
            print("🔄 No session to refresh")
            return
        }
        
        print("🔄 Refreshing session: \(sessionId)")
        
        do {
            let (_, newMessages) = try await apiService.resumeAgent(sessionId: sessionId)
            
            await MainActor.run {
                messages = newMessages
                rebuildToolCallState(from: newMessages)
                scrollRefreshTrigger = UUID()
                print("✅ Session refreshed with \(newMessages.count) messages")
            }
        } catch {
            print("⚠️ Failed to refresh session: \(error)")
        }
    }
}

// MARK: - Chat Session Model (matches goosed API)
struct ChatSession: Identifiable, Codable, Equatable {
    let id: String
    let description: String
    let messageCount: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case description
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.description == rhs.description &&
        lhs.messageCount == rhs.messageCount &&
        lhs.updatedAt == rhs.updatedAt
    }

    // Computed properties for UI display
    var title: String {
        return description.isEmpty ? "Untitled Session" : description
    }

    var lastMessage: String {
        return "\(messageCount) message\(messageCount == 1 ? "" : "s")"
    }

    var timestamp: Date {
        // Parse the ISO 8601 date string
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: updatedAt) ?? Date()
    }
}

// MARK: - Tool Call Data Structures
struct ToolCallWithTiming {
    let toolCall: ToolCall
    let startTime: Date
}

struct CompletedToolCall {
    let toolCall: ToolCall
    let result: ToolResult
    let duration: TimeInterval
    let completedAt: Date
}

#Preview {
    ChatView(
        showingSidebar: .constant(false), onBackToWelcome: {}, voiceManager: EnhancedVoiceManager())
}

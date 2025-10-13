import SwiftUI

struct ChatView: View {
    @Binding var showingSidebar: Bool
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

    // Voice features
    @StateObject private var voiceManager = EnhancedVoiceManager()

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
                                    completedTasks: getCompletedTasksForMessage(message.id)
                                )
                                .id(message.id)

                                // Show ONLY active/in-progress tool calls (completed ones are in the pill)
                                ForEach(getToolCallsForMessage(message.id), id: \.self) {
                                    toolCallId in
                                    if let activeCall = activeToolCalls[toolCallId] {
                                        HStack {
                                            Spacer()
                                            ToolCallProgressView(toolCall: activeCall.toolCall)
                                            Spacer()
                                        }
                                        .id("tool-\(toolCallId)")
                                    }
                                }
                            }

                            // Only show "thinking" indicator if no active tool calls
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
                            }

                            // Add space at the bottom so the last message can scroll above the input area
                            // This is actual content space, not padding, so it scrolls with the messages
                            Spacer()
                                .frame(height: 180)
                        }
                        .padding(.horizontal)
                        .padding(.top, apiService.isTrialMode ? 130 : 82)  // Extra space for trial banner
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
                        Color(UIColor.systemBackground).opacity(0.95),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                .allowsHitTesting(false)
            }

            // Floating input area
            VStack {
                Spacer()

                VStack(spacing: 0) {
                    // Show transcribed text while in voice mode
                    if voiceManager.voiceMode != .normal && !voiceManager.transcribedText.isEmpty {
                        HStack {
                            Text("Transcribing: \"\(voiceManager.transcribedText)\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .background(Color(UIColor.systemBackground).opacity(0.95))
                    }

                    // Input field with buttons
                    VStack(alignment: .leading, spacing: 12) {
                        // Text field on top
                        TextField("I want to...", text: $inputText, axis: .vertical)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                            .lineLimit(1...4)
                            .padding(.vertical, 8)
                            .disabled(voiceManager.voiceMode != .normal)
                            .onSubmit {
                                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                                {
                                    sendMessage()
                                }
                            }

                        // Buttons row at bottom
                        HStack(spacing: 10) {
                            // Plus button - file attachment
                            Button(action: {
                                print("File attachment tapped")
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .inset(by: 0.5)
                                            .stroke(Color(UIColor.separator), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            HStack(spacing: 10) {
                                // Voice mode indicator text
                                if voiceManager.voiceMode != .normal {
                                    Text(
                                        voiceManager.voiceMode == .audio
                                            ? "Transcribe" : "Full Audio"
                                    )
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.blue.opacity(0.1))
                                    )
                                }

                                // Audio/Voice button
                                Button(action: {
                                    // Cycle through voice modes
                                    voiceManager.cycleVoiceMode()
                                }) {
                                    Image(
                                        systemName: voiceManager.voiceMode == .normal
                                            ? "waveform" : "waveform.circle.fill"
                                    )
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(
                                        voiceManager.voiceMode == .normal ? .primary : .blue
                                    )
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .inset(by: 0.5)
                                            .stroke(Color(UIColor.separator), lineWidth: 0.5)
                                    )
                                }
                                .buttonStyle(.plain)

                                // Send/Stop button
                                Button(action: {
                                    if isLoading {
                                        stopStreaming()
                                    } else if !inputText.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty {
                                        sendMessage()
                                    }
                                }) {
                                    Image(systemName: isLoading ? "stop.fill" : "arrow.up")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundColor(
                                            isLoading
                                                ? .white : (inputText.isEmpty ? .gray : .white)
                                        )
                                        .frame(width: 32, height: 32)
                                        .background(
                                            isLoading
                                                ? Color.red
                                                : (inputText.trimmingCharacters(
                                                    in: .whitespacesAndNewlines
                                                ).isEmpty
                                                    ? Color.gray.opacity(0.3)
                                                    : Color.blue)
                                        )
                                        .cornerRadius(16)
                                }
                                .buttonStyle(.plain)
                                .disabled(
                                    !isLoading
                                        && inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty
                                )
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 21)
                            .fill(.regularMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 21)
                                    .fill(Color(UIColor.secondarySystemBackground).opacity(0.85))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 21)
                            .inset(by: 0.5)
                            .stroke(Color(UIColor.separator), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 0)
                }
            }

            // Custom navigation bar with background
            VStack(spacing: 0) {
                // Trial mode banner if applicable
                if apiService.isTrialMode {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.white)
                        Text(
                            "Trial Mode: connect to your own Goose agent for the full personal experience"
                        )
                        .font(.caption)
                        .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                }

                // Navigation bar
                HStack(spacing: 8) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showingSidebar.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 22))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("goose")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    // Empty space where settings was - keeps title centered
                    Color.clear
                        .frame(width: 22, height: 22)
                }
                .padding(.horizontal, 16)
                .padding(.top, 50)  // Account for status bar
                .padding(.bottom, 12)
                .background(
                    Color(UIColor.systemBackground)
                        .opacity(0.95)
                        .background(.regularMaterial)
                )
            }

            // Sidebar overlay (this can stay in ZStack as it's a modal)
            if showingSidebar {
                SidebarView(
                    isShowing: $showingSidebar,
                    isSettingsPresented: $isSettingsPresented,
                    onSessionSelect: { sessionId in
                        loadSession(sessionId)
                    },
                    onNewSession: {
                        createNewSession()
                    })
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(ConfigurationHandler.shared)
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

                    // Extend the system prompt with iOS-specific context
                    print("🔧 EXTENDING PROMPT FOR SESSION: \(sessionId)")
                    try await apiService.extendSystemPrompt(sessionId: sessionId)
                    print("✅ PROMPT EXTENDED FOR SESSION: \(sessionId)")

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
                    workingDirectory: "/tmp",
                    onEvent: { event in
                        handleSSEEvent(event)
                    },
                    onComplete: {
                        isLoading = false
                        currentStreamTask = nil
                    },
                    onError: { error in
                        isLoading = false
                        currentStreamTask = nil

                        print("🚨 Chat Error: \(error)")

                        let errorMessage = Message(
                            role: .assistant,
                            text: "❌ Error: \(error.localizedDescription)"
                        )
                        messages.append(errorMessage)
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

        case .ping:
            break
        }
    }

    private func stopStreaming() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
        isLoading = false
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

                // Extend the system prompt with iOS-specific context (same as new session)
                print("🔧 EXTENDING PROMPT FOR RESUMED SESSION: \(resumedSessionId)")
                try await apiService.extendSystemPrompt(sessionId: resumedSessionId)
                print("✅ PROMPT EXTENDED FOR RESUMED SESSION: \(resumedSessionId)")

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
}

// MARK: - Sidebar View
struct SidebarView: View {
    @Binding var isShowing: Bool
    @Binding var isSettingsPresented: Bool
    let onSessionSelect: (String) -> Void
    let onNewSession: () -> Void
    @State private var sessions: [ChatSession] = []

    var body: some View {
        ZStack {
            // Background overlay
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isShowing = false
                    }
                }

            // Sidebar panel
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    // Header with New Session button at top
                    HStack {
                        Button(action: {
                            onNewSession()
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isShowing = false
                            }
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.primary)
                                .frame(width: 32, height: 32)
                                .background(Color(.systemGray5))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isShowing = false
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))

                    Divider()

                    // Sessions list
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Sessions header
                            HStack {
                                Text("Sessions")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            ForEach(sessions) { session in
                                SessionRowView(session: session)
                                    .onTapGesture {
                                        onSessionSelect(session.id)
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            isShowing = false
                                        }
                                    }
                                Divider()
                                    .padding(.leading)
                            }
                        }
                    }

                    Spacer()

                    Divider()

                    // Bottom row: Settings button (matching PR #11 style)
                    Button(action: {
                        // Close sidebar immediately
                        isShowing = false
                        // Open settings immediately (sheet will present after sidebar closes)
                        isSettingsPresented = true
                    }) {
                        HStack {
                            Image(systemName: "gear")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)

                            Text("Settings")
                                .font(.system(size: 16))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(.systemBackground))
                }
                .frame(width: 280)
                .background(Color(.systemBackground))
                .offset(x: isShowing ? 0 : -280)

                Spacer()
            }
        }
        .onAppear {
            Task {
                await loadSessions()
            }
        }
    }

    private func loadSessions() async {
        let fetchedSessions = await GooseAPIService.shared.fetchSessions()
        await MainActor.run {
            self.sessions = fetchedSessions
        }
    }
}

// MARK: - Session Row View
struct SessionRowView: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(1)

            Text(session.lastMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            Text(formatDate(session.timestamp))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
// MARK: - Chat Session Model (matches goosed API)
struct ChatSession: Identifiable, Codable {
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
    ChatView(showingSidebar: .constant(false))
}

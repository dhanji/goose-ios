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
    
    // Memory management
    private let maxMessages = 50 // Limit messages to prevent memory issues
    private let maxToolCalls = 20 // Limit tool calls to prevent memory issues
    
    // Efficient scroll management
    @State private var scrollTimer: Timer?
    @State private var shouldAutoScroll = true
    @State private var scrollRefreshTrigger = UUID() // Force scroll refresh

    var body: some View {
        ZStack {
            // Main chat view
            VStack(spacing: 0) {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                                
                                // Show tool calls that belong to this message
                                ForEach(getToolCallsForMessage(message.id), id: \.self) { toolCallId in
                                    HStack {
                                        Spacer()
                                        if let activeCall = activeToolCalls[toolCallId] {
                                            ToolCallProgressView(toolCall: activeCall.toolCall)
                                        } else if let completedCall = completedToolCalls[toolCallId] {
                                            CompletedToolCallView(completedCall: completedCall)
                                        }
                                        Spacer()
                                    }
                                    .id("tool-\(toolCallId)")
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
                            }
                            
                            // Add bottom padding to account for floating input
                            Spacer()
                                .frame(height: 120)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
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
                }
            }
            
            // Floating Input Area
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    
                    // File upload button
                    Button(action: {
                        // TODO: Implement file upload
                        print("File upload tapped")
                    }) {
                        Image(systemName: "plus")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    
                    TextField("build, solve, create...", text: $inputText, axis: .vertical)
                        .padding(12)
                        .background(Color(.systemBackground))
                        .cornerRadius(25)
                        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                        .lineLimit(1...4)
                        .onSubmit {
                            sendMessage()
                        }

                    Button(action: {
                        if isLoading {
                            stopStreaming()
                        } else {
                            sendMessage()
                        }
                    }) {
                        Image(systemName: isLoading ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(
                                isLoading
                                    ? .red
                                    : (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? .gray : .blue))
                    }
                    .disabled(
                        !isLoading && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            
            // Sidebar
            if showingSidebar {
                SidebarView(isShowing: $showingSidebar, onSessionSelect: { sessionId in
                    loadSession(sessionId)
                }, onNewSession: {
                    createNewSession()
                })
            }
        }
        .onAppear {
            Task {
                await apiService.testConnection()
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

        startChatStream()
    }

    private func startChatStream() {
        Task {
            do {
                // Create session if we don't have one
                if currentSessionId == nil {
                    let (sessionId, initialMessages) = try await apiService.startAgent(workingDir: "/tmp")
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
                          let model = await apiService.readConfigValue(key: "GOOSE_MODEL") else {
                        throw APIError.noData
                    }
                    
                    print("🔧 UPDATING PROVIDER TO \(provider) WITH MODEL \(model)")
                    try await apiService.updateProvider(sessionId: sessionId, provider: provider, model: model)
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
                
                if let existingIndex = self.messages.firstIndex(where: { $0.id == incomingMessage.id }) {
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
                                created: incomingMessage.created, metadata: incomingMessage.metadata)
                        }
                    }

                    self.messages[existingIndex] = updatedMessage
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

        case .modelChange(let modelEvent):
            print("Model changed: \(modelEvent.model) (\(modelEvent.mode))")

        case .notification(let notificationEvent):
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
    
    private func limitMessages() {
        guard messages.count > maxMessages else { return }
        
        // Keep only the most recent messages, but always keep the first message (usually system prompt)
        let messagesToRemove = messages.count - maxMessages
        let startIndex = messages.count > 1 ? 1 : 0 // Keep first message if exists
        
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
        
        Task {
            do {
                // Resume the session
                let (resumedSessionId, sessionMessages) = try await apiService.resumeAgent(sessionId: sessionId)
                print("✅ SESSION RESUMED: \(resumedSessionId)")
                print("📝 Loaded \(sessionMessages.count) messages")
                
                // Read provider and model from config (same as new session)
                print("🔧 READING PROVIDER AND MODEL FROM CONFIG")
                guard let provider = await apiService.readConfigValue(key: "GOOSE_PROVIDER"),
                      let model = await apiService.readConfigValue(key: "GOOSE_MODEL") else {
                    throw APIError.noData
                }
                
                print("🔧 UPDATING PROVIDER TO \(provider) WITH MODEL \(model)")
                try await apiService.updateProvider(sessionId: resumedSessionId, provider: provider, model: model)
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
                    self.stopStreaming() // This clears currentStreamTask and isLoading
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
                        scrollRefreshTrigger = UUID() // Force UI refresh and scroll
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
                    // Header
                    HStack {
                        Text("Sessions")
                            .font(.title2)
                            .fontWeight(.bold)
                        
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
                            ForEach(sessions) { session in
                                SessionRowView(session: session)
                                    .onTapGesture {
                                        onSessionSelect(session.id)
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            isShowing = false
                                        }
                                    }
                                Divider()
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // New session button
                    Button(action: {
                        // Create new session
                        onNewSession()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isShowing = false
                        }
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("New Session")
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.blue)
                        .padding()
                    }
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

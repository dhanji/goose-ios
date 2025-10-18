import SwiftUI

struct WelcomeView: View {
    @Binding var showingSidebar: Bool
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    var onStartChat: (String) -> Void
    var onSessionSelect: (String) -> Void
    var cachedSessions: [ChatSession] = []  // Pass in cached sessions from ContentView
    
    // Voice features - shared with ChatView
    @ObservedObject var voiceManager: EnhancedVoiceManager
    
    // States for welcome view
    @State private var recentSessions: [ChatSession] = []
    @State private var isLoadingSessions = false
    @State private var isSettingsPresented = false
    @State private var showTrialInstructions = false
    
    // Animation states
    @State private var showSessionsTitle = false
    @State private var visibleSessionsCount = 0
    @State private var showTrialModeCard = false
    
    // Session card state
    @State private var selectedSession: ChatSession? = nil
    @State private var showSessionCard = false
    
    // Node focus state (for focus mode)
    @State private var focusedNodeSession: ChatSession? = nil
    @State private var focusedNodePosition: CGPoint = .zero
    
    // Access API service for trial mode check
    @StateObject private var apiService = GooseAPIService.shared
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Main content - use VStack with Spacer to push input to bottom
                VStack(spacing: 0) {
                    // Spacer for the welcome card (animated height)
                    Color.clear
                        .frame(height: isInputFocused ? 0 : 300)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isInputFocused)
                    
                    // Node Matrix Section - fills all remaining space above input
                    ZStack {
                        // Always render the space, just change the content
                        if isLoadingSessions {
                            // Loading state
                            VStack {
                                Spacer()
                                if showSessionsTitle {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .tint(.secondary)
                                        .transition(.opacity)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if recentSessions.isEmpty && !isInputFocused {
                            // Empty state
                            VStack {
                                Spacer()
                                if showSessionsTitle {
                                    VStack(spacing: 8) {
                                        Image(systemName: "calendar.badge.clock")
                                            .font(.system(size: 32))
                                            .foregroundColor(.secondary.opacity(0.5))
                                        
                                        Text("No sessions today")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                    }
                                    .transition(.opacity)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            // Node Matrix - fills all available space
                            if showSessionsTitle {
                                GeometryReader { matrixGeo in
                                    NodeMatrix(
                                        sessions: recentSessions,
                                        selectedSessionId: isInputFocused ? focusedNodeSession?.id : selectedSession?.id,
                                        onNodeTap: { session, position in
                                            // Convert position from NodeMatrix local space to global space
                                            let globalPosition = CGPoint(
                                                x: matrixGeo.frame(in: .global).minX + position.x,
                                                y: matrixGeo.frame(in: .global).minY + position.y
                                            )
                                            handleNodeTap(session, at: globalPosition)
                                        },
                                        showDraftNode: isInputFocused && focusedNodeSession == nil
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .transition(.opacity)
                            } else {
                                // Placeholder to maintain space before animation
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle()) // Make the entire area tappable
                    .onTapGesture {
                        // Dismiss keyboard and return to home when tapping outside chat input
                        if isInputFocused {
                            isInputFocused = false
                            focusedNodeSession = nil
                        }
                    }
                    
                    // Chat input at bottom - always present
                    ChatInputView(
                        text: $inputText,
                        isFocused: $isInputFocused,
                        voiceManager: voiceManager,
                        onSubmit: {
                            handleSubmit()
                        },
                        showTrialBanner: apiService.isTrialMode && showTrialModeCard,
                        onTrialBannerTap: {
                            showTrialInstructions = true
                        }
                    )
                }
                
                // Welcome Card overlaid on top (full bleed) - animated
                VStack {
                    WelcomeCard(
                        showingSidebar: $showingSidebar,
                        onAnimationComplete: {
                            // Show trial mode card if in trial mode
                            if apiService.isTrialMode {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    showTrialModeCard = true
                                }
                            }
                            
                            // Show sessions title
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    showSessionsTitle = true
                                }
                            }
                        }
                    )
                    
                    Spacer()
                }
                .offset(y: isInputFocused ? -350 : 0)
                .opacity(isInputFocused ? 0 : 1)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isInputFocused)
                .zIndex(1)
                .allowsHitTesting(!showSessionCard && !isInputFocused) // Disable interaction when session card is showing or input focused
                
                // Sessions Card - slides in from top, overlays WelcomeCard
                if showSessionCard, let session = selectedSession {
                    VStack {
                        SessionsCard(
                            session: session,
                            onClose: {
                                handleCloseSessionCard()
                            },
                            onSessionSelect: { sessionId in
                                onSessionSelect(sessionId)
                                handleCloseSessionCard()
                            }
                        )
                        
                        Spacer()
                    }
                    .zIndex(2)
                    .allowsHitTesting(true)
                    .transition(.identity)
                    .offset(y: showSessionCard ? 0 : -500)
                    .animation(.easeOut(duration: 0.35), value: showSessionCard)
                }
                
                // NodeFocus popover - overlaid on top, positioned near the node
                if let focusedSession = focusedNodeSession, isInputFocused {
                    let popoverWidth: CGFloat = 200
                    let popoverHeight: CGFloat = 100 // Approximate height
                    let offsetAboveNode: CGFloat = 70
                    
                    // Calculate optimal position with bounds checking
                    let targetX = focusedNodePosition.x
                    let targetY = focusedNodePosition.y - offsetAboveNode
                    
                    // Clamp X to keep popover on screen
                    let clampedX = min(max(targetX, popoverWidth / 2 + 16), geometry.size.width - popoverWidth / 2 - 16)
                    
                    // Clamp Y to keep popover on screen (account for safe area)
                    let clampedY = max(targetY, popoverHeight / 2 + 60)
                    
                    NodeFocus(
                        session: focusedSession,
                        onDismiss: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                focusedNodeSession = nil
                            }
                        }
                    )
                    .position(x: clampedX, y: clampedY)
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(3)
                    .allowsHitTesting(true)
                }
                
                // Safe area extension at the very top - covers the shadow
                // Switches color based on focus state: system background when focused (draft view),
                // WelcomeCard color when not focused
                SafeAreaExtension(useSystemBackground: isInputFocused)
                    .zIndex(10) // Increased from 3 to ensure it's always on top
                    .allowsHitTesting(false) // Don't block touches
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isInputFocused)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(ConfigurationHandler.shared)
        }
        .sheet(isPresented: $showTrialInstructions) {
            TrialModeInstructionsView()
        }
        .onChange(of: voiceManager.transcribedText) { oldValue, newText in
            // Update input text with transcribed text in real-time
            if !newText.isEmpty && voiceManager.voiceMode != .normal {
                inputText = newText
            }
        }
        .onChange(of: isInputFocused) { oldValue, newValue in
            // Clear focused node when input loses focus
            if !newValue {
                focusedNodeSession = nil
            }
        }
        .onAppear {
            // Set up voice manager callback for auto-sending messages
            voiceManager.onSubmitMessage = { message in
                inputText = message
                // Auto-send the message
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    handleSubmit()
                }
            }
            
            // Load recent sessions
            Task {
                await loadRecentSessions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RefreshSessions"))) { _ in
            // Refresh sessions when settings are saved
            Task {
                await loadRecentSessions()
            }
        }
    }
    
    // Handle message submission
    private func handleSubmit() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        if let focusedSession = focusedNodeSession {
            // Route to existing session
            print("📨 Routing message to session: \(focusedSession.id)")
            onSessionSelect(focusedSession.id)
            
            // Send the message to that session via notification
            NotificationCenter.default.post(
                name: Notification.Name("SendMessageToSession"),
                object: nil,
                userInfo: ["message": trimmedText, "sessionId": focusedSession.id]
            )
            
            // Clear state
            focusedNodeSession = nil
        } else {
            // Start new chat
            onStartChat(inputText)
        }
    }
    
    // Handle node tap
    private func handleNodeTap(_ session: ChatSession, at position: CGPoint) {
        if isInputFocused {
            // In focus mode - show NodeFocus popover
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                focusedNodeSession = session
                focusedNodePosition = position
            }
        } else {
            // Not in focus mode - show SessionCard
            selectedSession = session
            showSessionCard = true
        }
    }
    
    // Handle close session card
    private func handleCloseSessionCard() {
        showSessionCard = false
        
        // Clear selected session after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            selectedSession = nil
        }
    }
    
    // Load recent sessions - use cached if available, otherwise fetch
    private func loadRecentSessions() async {
        // Use cached sessions immediately if available
        if !cachedSessions.isEmpty {
            await MainActor.run {
                recentSessions = Array(cachedSessions.prefix(30))
                isLoadingSessions = false
            }
            
            // Optionally fetch fresh data in background for next time
            // This is non-blocking and updates ContentView's cache
            Task.detached(priority: .background) {
                _ = await GooseAPIService.shared.fetchSessions()
            }
        } else {
            // No cache, need to fetch
            isLoadingSessions = true
            
            // Fetch insights and sessions in parallel
            async let insightsTask = GooseAPIService.shared.fetchInsights()
            async let sessionsTask = GooseAPIService.shared.fetchSessions()
            
            let (_, sessions) = await (insightsTask, sessionsTask)
            
            await MainActor.run {
                recentSessions = Array(sessions.prefix(30))
                isLoadingSessions = false
            }
        }
    }
}

// MARK: - Welcome Session Row View
struct WelcomeSessionRowView: View {
    let session: ChatSession
    @Environment(\.colorScheme) var colorScheme
    
    var formattedTimestamp: String {
        // Parse the ISO8601 date string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let sessionDate = formatter.date(from: session.updatedAt) else {
            return session.updatedAt
        }
        
        let now = Date()
        let interval = now.timeIntervalSince(sessionDate)
        
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)
        
        if minutes < 60 {
            return "\(minutes) Minute\(minutes == 1 ? "" : "s") ago"
        } else if hours < 24 {
            return "\(hours) Hour\(hours == 1 ? "" : "s") ago"
        } else if days == 1 {
            return "Yesterday"
        } else {
            return "\(days) Days ago"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name.isEmpty ? "Session \(session.id.prefix(8))" : session.name)
                .font(.system(size: 16))
                .foregroundColor(.primary)
                .lineLimit(1)
            
            Text(formattedTimestamp)
                .font(.system(size: 12))
                .tracking(0.06)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    WelcomeView(
        showingSidebar: .constant(false),
        onStartChat: { text in
            print("Starting chat with: \(text)")
        },
        onSessionSelect: { sessionId in
            print("Selected session: \(sessionId)")
        },
        voiceManager: EnhancedVoiceManager()
    )
}

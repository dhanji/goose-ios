import SwiftUI

struct ContentView: View {
    @State private var isSettingsPresented = false
    @State private var showingSidebar = false
    @State private var showingSplash = true
    @State private var hasActiveChat = false
    @State private var initialMessage = ""
    @State private var shouldSendInitialMessage = false
    @State private var selectedSessionId: String?
    @State private var sessionName: String = "New Session"
    @State private var cachedSessions: [ChatSession] = [] // Preloaded sessions
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreSessions: Bool = true
    @State private var currentDaysLoaded: Int = 5  // Track how many days we've loaded
    private let initialDaysBack: Int = 5  // Load sessions from last 5 days initially
    private let loadMoreDaysIncrement: Int = 5  // Load 5 more days when "Load More" is clicked

    // MARK: - Load More Sessions (load older sessions)
    func loadMoreSessions() async {
        guard !isLoadingMore && hasMoreSessions else { return }
        
        await MainActor.run {
            isLoadingMore = true
        }
        
        let allSessions = await GooseAPIService.shared.fetchSessions()
        
        await MainActor.run {
            // Calculate current date range
            let calendar = Calendar.current  // Use local timezone
            let now = Date()
            
            // Increment the days loaded
            let newDaysBack = currentDaysLoaded + loadMoreDaysIncrement
            let cutoffDate = calendar.date(byAdding: .day, value: -newDaysBack, to: now) ?? now
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            
            let sessionsInRange = allSessions.filter { session in
                guard let sessionDate = formatter.date(from: session.updatedAt) else {
                    return false
                }
                return sessionDate >= cutoffDate
            }
            
            let previousCount = cachedSessions.count
            self.cachedSessions = sessionsInRange
            self.hasMoreSessions = allSessions.count > sessionsInRange.count
            
            let newCount = sessionsInRange.count - previousCount
            
            // Update the days loaded tracker
            self.currentDaysLoaded = newDaysBack
            
            print("✅ Loaded \(newCount) more sessions (now showing last \(newDaysBack) days, total: \(sessionsInRange.count))")
            
            if newCount == 0 {
                self.hasMoreSessions = false
                print("✅ No more sessions to load")
            }
            
            isLoadingMore = false
        }
    }
    
    // Helper to estimate days loaded based on session dates
    private func calculateDaysLoaded(from sessions: [ChatSession]) -> Int {
        guard let oldestSession = sessions.last else { return initialDaysBack }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        guard let oldestDate = formatter.date(from: oldestSession.updatedAt) else {
            return initialDaysBack
        }
        
        let calendar = Calendar.current  // Use local timezone
        let days = calendar.dateComponents([.day], from: oldestDate, to: Date()).day ?? initialDaysBack
        return max(days, initialDaysBack)
    }
    
    @EnvironmentObject var configurationHandler: ConfigurationHandler
    
    // Shared voice managers across WelcomeView and ChatView
    @StateObject private var sharedVoiceManager = EnhancedVoiceManager()
    @StateObject private var sharedContinuousVoiceManager = ContinuousVoiceManager()
    
    // Dynamic sidebar width based on device
    private var sidebarWidth: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        if UIDevice.current.userInterfaceIdiom == .pad {
            return screenWidth * 0.5 // 50% on iPad
        } else {
            return screenWidth // 100% on iPhone
        }
    }

    var body: some View {
        if showingSplash {
            // Splash Screen
            SplashScreenView(isActive: $showingSplash)
                .onAppear {
                    // Warm up the demo server if in trial mode (non-blocking)
                    warmUpServer()
                    // Preload sessions on app launch
                    Task {
                        await preloadSessions()
                    }
                }
        } else {
            // Main content with sidebar (following PR pattern)
            ZStack(alignment: .leading) {
                // Main content - full height (stays in place)
                GeometryReader { geometry in
                    NavigationStack {
                        if !hasActiveChat {
                            // Welcome View when no active chat
                            WelcomeView(
                                showingSidebar: $showingSidebar,
                                onStartChat: { message in
                                // Start new chat with the message
                                initialMessage = message
                                shouldSendInitialMessage = !message.isEmpty
                                selectedSessionId = nil // Clear session ID for new chat
                                withAnimation {
                                    hasActiveChat = true
                                }
                            }, onSessionSelect: { sessionId in
                                // Load existing session
                                selectedSessionId = sessionId
                                withAnimation {
                                    hasActiveChat = true
                                }
                            },
                                cachedSessions: cachedSessions,  // Pass cached sessions
                                onLoadMore: {  // Pass load more callback for NodeMatrix
                                    await loadMoreSessions()
                                },
                                voiceManager: sharedVoiceManager,
                                continuousVoiceManager: sharedContinuousVoiceManager
                            )
                            .navigationBarHidden(true)
                        } else {
                            // Chat View when there's an active chat
                            ChatViewWithInitialMessage(
                                showingSidebar: $showingSidebar,
                                voiceManager: sharedVoiceManager,
                                continuousVoiceManager: sharedContinuousVoiceManager,
                                initialMessage: initialMessage,
                                shouldSendMessage: shouldSendInitialMessage,
                                selectedSessionId: selectedSessionId,
                                onMessageSent: {
                                    // Clear the initial message after sending
                                    initialMessage = ""
                                    shouldSendInitialMessage = false
                                    selectedSessionId = nil
                                },
                                onBackToWelcome: {
                                    // Return to welcome screen and refresh sessions
                                    withAnimation {
                                        hasActiveChat = false
                                    }
                                    // Refresh sessions when returning to welcome view
                                    Task {
                                        await refreshSessionsAfterChat()
                                    }
                                }
                            )
                            .navigationBarHidden(true)
                        }
                    }
                    .sheet(isPresented: $isSettingsPresented) {
                        SettingsView()
                            .environmentObject(configurationHandler)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color(UIColor.systemBackground))
                }
                .edgesIgnoringSafeArea(.all)
                
                // Sidebar overlay - slides in independently
                if showingSidebar {
                    SidebarView(
                        isShowing: $showingSidebar,
                        isSettingsPresented: $isSettingsPresented,
                        cachedSessions: $cachedSessions,
                        onSessionSelect: { sessionId in
                            // Find session to get its description
                            if let session = cachedSessions.first(where: { $0.id == sessionId }) {
                                let name = session.description.isEmpty ? "Untitled Session" : session.description
                                navigateToSession(sessionId: sessionId, sessionName: name)
                            }
                        },
                        onNewSession: {
                            navigateToSession(sessionId: nil)
                            Task {
                                await preloadSessions()
                            }
                        },
                        onLoadMore: {
                            await loadMoreSessions()
                        },
                        isLoadingMore: isLoadingMore,
                        hasMoreSessions: hasMoreSessions
                    )
                    .transition(.move(edge: .leading))
                    .animation(.easeInOut(duration: 0.25), value: showingSidebar)
                    .zIndex(1)  // Ensure sidebar is above main content
                    // Note: Removed onAppear preload to preserve loaded sessions
                    // Sessions are loaded on app launch and via "Load More" button
                }
            }
            .overlay(alignment: .top) {
                if configurationHandler.isConfiguring {
                    ConfigurationStatusView(message: "Configuring...", isLoading: true)
                } else if configurationHandler.configurationSuccess {
                    ConfigurationStatusView(message: "✅ Configuration successful!", isSuccess: true)
                } else if let error = configurationHandler.configurationError {
                    ConfigurationStatusView(
                        message: error, 
                        isError: true,
                        isTailscaleError: configurationHandler.isTailscaleError,
                        onTailscaleAction: {
                            configurationHandler.openTailscale()
                        }
                    )
                    .onTapGesture {
                        configurationHandler.clearError()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RefreshSessions"))) { _ in
                // Refresh sessions when settings are saved
                Task {
                    await preloadSessions()
                }
            }
        }
    }
    
    // MARK: - Navigation Helpers
    
    /// Navigate to a session (existing or new)
    private func navigateToSession(sessionId: String?, sessionName: String = "New Session") {
        self.selectedSessionId = sessionId
        self.sessionName = sessionName
        self.initialMessage = ""
        self.shouldSendInitialMessage = false
        withAnimation {
            self.showingSidebar = false
            self.hasActiveChat = true
        }
    }
    
    // MARK: - Session Management
    
    /// Refresh sessions after returning from chat (to show new sessions)
    private func refreshSessionsAfterChat() async {
        print("🔄 Refreshing sessions after chat...")
        let fetchedSessions = await GooseAPIService.shared.fetchSessions()
        
        await MainActor.run {
            // Use UTC calendar for date comparison
            let calendar = Calendar.current  // Use local timezone
            let now = Date()
            
            // Use the tracked days loaded value
            let cutoffDate = calendar.date(byAdding: .day, value: -currentDaysLoaded, to: now) ?? now
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            
            let sessionsInRange = fetchedSessions.filter { session in
                guard let sessionDate = formatter.date(from: session.updatedAt) else {
                    return false
                }
                return sessionDate >= cutoffDate
            }
            
            self.cachedSessions = sessionsInRange
            self.hasMoreSessions = fetchedSessions.count > sessionsInRange.count
            
            print("✅ Refreshed \(self.cachedSessions.count) sessions (last \(self.currentDaysLoaded) days)")
            print("   - Total sessions available: \(fetchedSessions.count)")
        }
    }
    
    // Preload sessions from last 5 days on app launch
    // Preload sessions from last 5 days on app launch
    // Preload sessions from last 5 days on app launch
    private func preloadSessions() async {
        print("📥 Attempting to preload sessions...")
        let fetchedSessions = await GooseAPIService.shared.fetchSessions()
        
        await MainActor.run {
            // Use UTC calendar for date comparison to match session timestamps
            let calendar = Calendar.current  // Use local timezone
            let now = Date()
            let cutoffDate = calendar.date(byAdding: .day, value: -initialDaysBack, to: now) ?? now
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            
            print("📅 DEBUG: Current time (UTC): \(formatter.string(from: now))")
            print("📅 DEBUG: Cutoff date (5 days ago): \(formatter.string(from: cutoffDate))")
            print("📅 DEBUG: Total sessions from API: \(fetchedSessions.count)")
            
            // Check for duplicate session IDs
            let sessionIds = fetchedSessions.map { $0.id }
            let uniqueIds = Set(sessionIds)
            if sessionIds.count != uniqueIds.count {
                print("⚠️ DEBUG: DUPLICATE SESSION IDs DETECTED!")
                print("   Total sessions: \(sessionIds.count)")
                print("   Unique IDs: \(uniqueIds.count)")
                print("   Duplicates: \(sessionIds.count - uniqueIds.count)")
            }
            
            // Show ALL sessions from last 7 days for debugging
            let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            let recentForDebug = fetchedSessions.filter { session in
                guard let sessionDate = formatter.date(from: session.updatedAt) else { return false }
                return sessionDate >= sevenDaysAgo
            }
            
            print("📅 DEBUG: ALL sessions from last 7 days (\(recentForDebug.count) total):")
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd (EEEE)"
            dayFormatter.timeZone = TimeZone(identifier: "UTC")
            
            for session in recentForDebug.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                if let date = formatter.date(from: session.updatedAt) {
                    let dayStr = dayFormatter.string(from: date)
                    let desc = session.description.isEmpty ? "[Untitled]" : session.description
                    print("   \(session.updatedAt) (\(dayStr)) - \(desc) [msgs: \(session.messageCount)]")
                }
            }
            
            var includedCount = 0
            var filteredCount = 0
            var parseErrors = 0
            
            let recentSessions = fetchedSessions.filter { session in
                guard let sessionDate = formatter.date(from: session.updatedAt) else {
                    print("⚠️ DEBUG: Failed to parse date: \(session.updatedAt) for session: \(session.description)")
                    parseErrors += 1
                    return false
                }
                
                let isIncluded = sessionDate >= cutoffDate
                if isIncluded {
                    includedCount += 1
                } else {
                    filteredCount += 1
                }
                
                return isIncluded
            }
            
            // Load all sessions within the initial time window
            self.cachedSessions = recentSessions
            self.currentDaysLoaded = initialDaysBack
            self.hasMoreSessions = fetchedSessions.count > recentSessions.count
            
            print("📅 DEBUG: Filtering results:")
            print("   - Included (within 5 days): \(includedCount)")
            print("   - Filtered (older than 5 days): \(filteredCount)")
            print("   - Parse errors: \(parseErrors)")
            print("✅ Preloaded \(self.cachedSessions.count) sessions from last \(initialDaysBack) days")
            print("   - Total sessions available: \(fetchedSessions.count)")
            print("   - Older sessions available: \(fetchedSessions.count - recentSessions.count)")
            
            // Show what we actually loaded
            print("📅 DEBUG: Loaded sessions by date:")
            let groupedByDate = Dictionary(grouping: recentSessions) { session -> String in
                guard let date = formatter.date(from: session.updatedAt) else { return "unknown" }
                return dayFormatter.string(from: date)
            }
            for (date, sessions) in groupedByDate.sorted(by: { $0.key > $1.key }) {
                print("   \(date): \(sessions.count) sessions")
            }
            
            if self.cachedSessions.isEmpty {
                print("⚠️ No sessions preloaded - server may not be connected or no sessions exist")
            }
        }
    }
    
    /// Warm up the server on first launch (non-blocking)
    private func warmUpServer() {
        // Check if we're using the demo server
        let baseURL = UserDefaults.standard.string(forKey: "goose_base_url") ?? "https://demo-goosed.fly.dev"
        
        // Only warm up if it's the demo server
        if baseURL.contains("demo-goosed.fly.dev") {
            Task {
                // Fire-and-forget warm-up request
                // We don't care about the response, just want to wake up the server
                if let url = URL(string: baseURL) {
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 10
                    
                    do {
                        // Perform the request but don't wait or care about response
                        let _ = try await URLSession.shared.data(for: request)
                        print("🔥 Demo server warmed up")
                    } catch {
                        // Silently ignore any errors - this is just a warm-up
                        print("🔥 Demo server warm-up attempted")
                    }
                }
            }
        }
    }
}

struct ConfigurationStatusView: View {
    let message: String
    var isLoading = false
    var isSuccess = false
    var isError = false
    var isTailscaleError = false
    var onTailscaleAction: (() -> Void)?
    
    var backgroundColor: Color {
        if isSuccess { return .green }
        if isError && isTailscaleError { return .blue }  // Friendly blue for Tailscale
        if isError { return .red }
        return .blue
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
                
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                
                if isError && !isTailscaleError {
                    Text("Tap to dismiss")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            
            if isTailscaleError {
                Button(action: {
                    onTailscaleAction?()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Open Tailscale")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .cornerRadius(6)
                }
                
                Text("Tap anywhere to dismiss")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(backgroundColor)
        .cornerRadius(8)
        .shadow(radius: 4)
        .padding(.top, 50) // Account for nav bar
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(), value: isLoading)
        .animation(.spring(), value: isSuccess)
        .animation(.spring(), value: isError)
    }
}

// Wrapper to handle initial message and session loading
struct ChatViewWithInitialMessage: View {
    @Binding var showingSidebar: Bool
    @ObservedObject var voiceManager: EnhancedVoiceManager
    @ObservedObject var continuousVoiceManager: ContinuousVoiceManager
    let initialMessage: String
    let shouldSendMessage: Bool
    let selectedSessionId: String?
    let onMessageSent: () -> Void
    let onBackToWelcome: () -> Void
    
    var body: some View {
        ChatView(showingSidebar: $showingSidebar, onBackToWelcome: onBackToWelcome, voiceManager: voiceManager, continuousVoiceManager: continuousVoiceManager)
            .onAppear {
                // Load session if one was selected
                if let sessionId = selectedSessionId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(
                            name: Notification.Name("LoadSession"),
                            object: nil,
                            userInfo: ["sessionId": sessionId]
                        )
                        onMessageSent()
                    }
                } else if shouldSendMessage && !initialMessage.isEmpty {
                    // Send the initial message after a brief delay to ensure view is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NotificationCenter.default.post(
                            name: Notification.Name("SendInitialMessage"),
                            object: nil,
                            userInfo: ["message": initialMessage]
                        )
                        onMessageSent()
                    }
                }
            }
    }

}

#Preview {
    ContentView()
        .environmentObject(ConfigurationHandler.shared)
}

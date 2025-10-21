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
    private let sessionsPerPage: Int = 30
    private let maxDaysBack: Int = 90  // Only load sessions from last 90 days

    // MARK: - Load More Sessions
    func loadMoreSessions() async {
        guard !isLoadingMore && hasMoreSessions else { return }
        
        await MainActor.run {
            isLoadingMore = true
        }
        
        let allSessions = await GooseAPIService.shared.fetchSessions()
        
        await MainActor.run {
            // Filter sessions to only include those within the date boundary
            let calendar = Calendar.current
            let cutoffDate = calendar.date(byAdding: .day, value: -maxDaysBack, to: Date()) ?? Date()
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            
            let recentSessions = allSessions.filter { session in
                guard let sessionDate = formatter.date(from: session.updatedAt) else {
                    return false
                }
                return sessionDate >= cutoffDate
            }
            
            let currentCount = cachedSessions.count
            let nextBatch = Array(recentSessions.prefix(currentCount + sessionsPerPage))
            
            if nextBatch.count > currentCount {
                self.cachedSessions = nextBatch
                self.hasMoreSessions = recentSessions.count > nextBatch.count
                print("✅ Loaded \(nextBatch.count - currentCount) more sessions (total: \(nextBatch.count), filtered to last \(maxDaysBack) days)")
            } else {
                self.hasMoreSessions = false
                print("✅ No more sessions to load (reached \(maxDaysBack)-day boundary or end of sessions)")
            }
            
            isLoadingMore = false
        }
    }
    @EnvironmentObject var configurationHandler: ConfigurationHandler
    
    // Shared voice manager across WelcomeView and ChatView
    @StateObject private var sharedVoiceManager = EnhancedVoiceManager()
    
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
                // Main content - full height
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
                                onLoadMore: {  // NEW: Pass load more callback for NodeMatrix
                                    await loadMoreSessions()
                                },
                                voiceManager: sharedVoiceManager
                            )
                            .navigationBarHidden(true)
                        } else {
                            // Chat View when there's an active chat
                            ChatViewWithInitialMessage(
                                showingSidebar: $showingSidebar,
                                voiceManager: sharedVoiceManager,
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
                                    // Return to welcome screen
                                    withAnimation {
                                        hasActiveChat = false
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
                    .offset(x: showingSidebar ? sidebarWidth : 0) // Offset content when sidebar shows
                    .animation(.easeInOut(duration: 0.3), value: showingSidebar)
                                    }
                .edgesIgnoringSafeArea(.all)
                
                // Sidebar overlay
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
    
    // Preload sessions in background
    private func preloadSessions() async {
        print("📥 Attempting to preload sessions...")
        let fetchedSessions = await GooseAPIService.shared.fetchSessions()
        
        await MainActor.run {
            // Filter sessions to only include those within the date boundary
            let calendar = Calendar.current
            let cutoffDate = calendar.date(byAdding: .day, value: -maxDaysBack, to: Date()) ?? Date()
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            
            let recentSessions = fetchedSessions.filter { session in
                guard let sessionDate = formatter.date(from: session.updatedAt) else {
                    return false
                }
                return sessionDate >= cutoffDate
            }
            
            self.cachedSessions = Array(recentSessions.prefix(sessionsPerPage))
            self.hasMoreSessions = recentSessions.count > sessionsPerPage
            print("✅ Preloaded \(self.cachedSessions.count) sessions (filtered to last \(maxDaysBack) days)")
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
    let initialMessage: String
    let shouldSendMessage: Bool
    let selectedSessionId: String?
    let onMessageSent: () -> Void
    let onBackToWelcome: () -> Void
    
    var body: some View {
        ChatView(showingSidebar: $showingSidebar, onBackToWelcome: onBackToWelcome, voiceManager: voiceManager)
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

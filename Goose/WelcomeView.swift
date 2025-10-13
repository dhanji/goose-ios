import SwiftUI

struct WelcomeView: View {
    @Binding var showingSidebar: Bool
    @State private var inputText = ""
    @Environment(\.colorScheme) var colorScheme
    var onStartChat: (String) -> Void
    var onSessionSelect: (String) -> Void
    
    // States for welcome view
    @State private var recentSessions: [ChatSession] = []
    @State private var isLoadingSessions = true
    @State private var isSettingsPresented = false
    
    // Animation states
    @State private var displayedText = ""
    @State private var showSessionsTitle = false
    @State private var visibleSessionsCount = 0
    @State private var showLogo = false
    private let fullText = "Morning!\nWhat do you want to do?"
    
    var body: some View {
        VStack(spacing: 0) {
            // Top navigation bar
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: {
                        isSettingsPresented = true
                    }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 22))
                            .foregroundColor(.primary)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 66)
                .padding(.bottom, 8)
            }
            .background(Color(UIColor.systemBackground).opacity(0.95))
            .shadow(color: Color.black.opacity(0.05), radius: 0, y: 1)
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Greeting text with goose logo
                    HStack(alignment: .top, spacing: 16) {
                        Text(displayedText)
                            .font(.system(size: 20, weight: .medium))
                            .lineSpacing(6)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        if showLogo {
                            Image("GooseLogo")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundColor(.primary)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.top, 32)
                    
                    // Recent Sessions Section
                    VStack(alignment: .leading, spacing: 16) {
                        if showSessionsTitle {
                            Text("RECENT SESSIONS")
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(1.02)
                                .foregroundColor(.secondary)
                                .padding(.top, 16)
                        }
                        
                        if isLoadingSessions && showSessionsTitle {
                            // Loading state
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.secondary)
                                Spacer()
                            }
                            .frame(height: 100)
                        } else if recentSessions.isEmpty && showSessionsTitle {
                            // Empty state
                            Text("No recent sessions")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 32)
                        } else {
                            // Session list - show sessions one by one
                            VStack(spacing: 24) {
                                ForEach(Array(recentSessions.prefix(3).enumerated()), id: \.element.id) { index, session in
                                    if index < visibleSessionsCount {
                                        WelcomeSessionRowView(session: session)
                                            .transition(.opacity)
                                            .onTapGesture {
                                                // Load the session when tapped
                                                onSessionSelect(session.id)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    
                    Spacer(minLength: 180) // Space for input box
                }
                .padding(.horizontal, 16)
            }
            
            // Bottom input area
            VStack(alignment: .leading, spacing: 12) {
                // Text field on top
                TextField("I want to...", text: $inputText, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .lineLimit(1...4)
                    .padding(.vertical, 8)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onStartChat(inputText)
                        }
                    }
                
                // Buttons row at bottom
                HStack(spacing: 10) {
                    Spacer()
                    
                    // Send button
                    Button(action: {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onStartChat(inputText)
                        }
                    }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(colorScheme == .dark ? .black : .white)
                            .frame(width: 32, height: 32)
                            .background(
                                inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty 
                                ? Color.gray.opacity(0.3) 
                                : (colorScheme == .dark ? Color.white : Color.black)
                            )
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(21)
            .overlay(
                RoundedRectangle(cornerRadius: 21)
                    .inset(by: 0.5)
                    .stroke(Color(UIColor.separator), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(ConfigurationHandler.shared)
        }
        .onAppear {
            // Start typewriter animation
            startTypewriterEffect()
            
            // Load recent sessions
            Task {
                await loadRecentSessions()
            }
        }
    }
    
    // Typewriter effect for greeting text
    private func startTypewriterEffect() {
        displayedText = ""
        
        // Fast typewriter effect - 20ms per character
        for (index, character) in fullText.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.02) {
                displayedText.append(character)
                
                // When text is complete, show logo
                if displayedText == fullText {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        showLogo = true
                    }
                    
                    // Show sessions title
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showSessionsTitle = true
                        }
                        
                        // Show sessions one by one quickly (100ms between each)
                        for i in 0..<min(3, recentSessions.count) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.1) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    visibleSessionsCount = i + 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Load recent sessions from API
    private func loadRecentSessions() async {
        isLoadingSessions = true
        
        // Simulate delay for loading animation
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        let sessions = await GooseAPIService.shared.fetchSessions()
        
        await MainActor.run {
            recentSessions = Array(sessions.prefix(3))
            isLoadingSessions = false
            
            // Update visible count if sessions loaded after animation
            if showSessionsTitle && visibleSessionsCount == 0 {
                for i in 0..<min(3, recentSessions.count) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            visibleSessionsCount = i + 1
                        }
                    }
                }
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
            Text(session.description.isEmpty ? "Session \(session.id.prefix(8))" : session.description)
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
        }
    )
}

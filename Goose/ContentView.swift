import SwiftUI

struct ContentView: View {
    @State private var isSettingsPresented = false
    @State private var showingSidebar = false
    @State private var showingSplash = true
    @State private var hasActiveChat = false
    @State private var initialMessage = ""
    @State private var shouldSendInitialMessage = false
    @EnvironmentObject var configurationHandler: ConfigurationHandler

    var body: some View {
        if showingSplash {
            // Splash Screen
            SplashScreenView(isActive: $showingSplash)
        } else {
            NavigationView {
                if !hasActiveChat {
                    // Welcome View when no active chat
                    WelcomeView(showingSidebar: $showingSidebar) { message in
                        // Start new chat with the message
                        initialMessage = message
                        shouldSendInitialMessage = !message.isEmpty
                        withAnimation {
                            hasActiveChat = true
                        }
                    }
                    .navigationBarHidden(true)
                } else {
                    // Chat View when there's an active chat
                    ChatViewWithInitialMessage(
                        showingSidebar: $showingSidebar,
                        initialMessage: initialMessage,
                        shouldSendMessage: shouldSendInitialMessage,
                        onMessageSent: {
                            // Clear the initial message after sending
                            initialMessage = ""
                            shouldSendInitialMessage = false
                        }
                    )
                    .navigationBarHidden(true)
                    .sheet(isPresented: $isSettingsPresented) {
                        SettingsView()
                            .environmentObject(configurationHandler)
                    }
                }
            }
            .overlay(alignment: .top) {
                if configurationHandler.isConfiguring {
                    ConfigurationStatusView(message: "Configuring...", isLoading: true)
                } else if configurationHandler.configurationSuccess {
                    ConfigurationStatusView(message: "✅ Configuration successful!", isSuccess: true)
                } else if let error = configurationHandler.configurationError {
                    ConfigurationStatusView(message: "❌ \(error)", isError: true)
                        .onTapGesture {
                            configurationHandler.clearError()
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
    
    var backgroundColor: Color {
        if isSuccess { return .green }
        if isError { return .red }
        return .blue
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
            }
            
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
            
            if isError {
                Text("Tap to dismiss")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
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

// Wrapper to handle initial message
struct ChatViewWithInitialMessage: View {
    @Binding var showingSidebar: Bool
    let initialMessage: String
    let shouldSendMessage: Bool
    let onMessageSent: () -> Void
    
    var body: some View {
        ChatView(showingSidebar: $showingSidebar)
            .onAppear {
                if shouldSendMessage && !initialMessage.isEmpty {
                    // Send the initial message after a brief delay to ensure view is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Access the ChatView's input and send functionality
                        // This is a bit hacky but works for now
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

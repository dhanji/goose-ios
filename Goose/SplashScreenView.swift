import SwiftUI

struct SplashScreenView: View {
    @Binding var isActive: Bool
    @State private var logoOpacity: Double = 0.0
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ZStack {
            // Use system background color
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            
            // Goose logo centered
            Image("GooseLogo")
                .resizable()
                .renderingMode(.template)
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .opacity(logoOpacity)
        }
        .onAppear {
            // Fade in logo
            withAnimation(.easeIn(duration: 0.5)) {
                logoOpacity = 1.0
            }
            
            // After 1.5 seconds, transition to main content
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.5)) {
                    isActive = false
                }
            }
        }
    }
}

#Preview {
    SplashScreenView(isActive: .constant(true))
}

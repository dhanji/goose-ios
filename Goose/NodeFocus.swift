import SwiftUI

struct NodeFocus: View {
    let session: ChatSession
    let onDismiss: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with session title
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name.isEmpty ? "Session \(session.id.prefix(8))" : session.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    Text("\(session.messageCount) message\(session.messageCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Close button
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            
            // Info text
            Text("Your message will continue this session")
                .font(.system(size: 11))
                .foregroundColor(.blue)
                .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 200) // Fixed width
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ?
                      Color(red: 0.15, green: 0.15, blue: 0.18) :
                      Color(red: 0.96, green: 0.96, blue: 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    Color.blue.opacity(0.3),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    ZStack {
        Color(UIColor.systemBackground)
            .ignoresSafeArea()
        
        NodeFocus(
            session: ChatSession(
                id: "test-123",
                name: "Working on iOS app features",
                messageCount: 12,
                createdAt: "2024-01-15T10:30:00Z",
                updatedAt: "2024-01-15T14:45:00Z"
            ),
            onDismiss: {
                print("Dismiss tapped")
            }
        )
    }
}

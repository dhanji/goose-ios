import SwiftUI

struct NodeMatrix: View {
    let sessions: [ChatSession]
    let selectedSessionId: String?
    let onNodeTap: (ChatSession, CGPoint) -> Void
    var showDraftNode: Bool = false
    @Environment(\.colorScheme) var colorScheme
    @State private var daysOffset: Int = 0 // 0 = today, 1 = yesterday, etc.
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging: Bool = false
    @State private var pulseAnimation = false // For draft node pulsing
    
    // Get the date for the current offset
    private var targetDate: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -daysOffset, to: Date()) ?? Date()
    }
    
    // Filter sessions for the target day
    private var daySessions: [ChatSession] {
        let calendar = Calendar.current
        
        let filtered = sessions.filter { session in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            
            guard let sessionDate = formatter.date(from: session.updatedAt) else {
                return false
            }
            
            return calendar.isDate(sessionDate, inSameDayAs: targetDate)
        }
        
        return filtered.sorted { session1, session2 in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date1 = formatter.date(from: session1.updatedAt),
                  let date2 = formatter.date(from: session2.updatedAt) else {
                return false
            }
            return date1 < date2
        }
    }
    
    // Format the date label
    private var dateLabel: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        
        if calendar.isDateInToday(targetDate) {
            return "Today"
        } else if calendar.isDateInYesterday(targetDate) {
            return "Yesterday"
        } else {
            formatter.dateStyle = .medium
            return formatter.string(from: targetDate)
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Date label header - left aligned
                HStack {
                    HStack(spacing: 8) {
                        Text(dateLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        // Right indicator (for going to past)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        // Left indicator (only show if not on today)
                        if daysOffset > 0 {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                    
                    Spacer()
                }
                .padding(.top, 24)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                
                // Node content area - fills all available space
                GeometryReader { nodeGeometry in
                    ZStack {
                        // Empty state (only show if no draft node and no sessions)
                        if daySessions.isEmpty && !showDraftNode {
                            VStack(spacing: 8) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary.opacity(0.5))
                                
                                Text("No sessions on \(dateLabel.lowercased())")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        // Draw connections (lines between nodes)
                        if daySessions.count > 1 {
                            Path { path in
                                for i in 0..<(daySessions.count - 1) {
                                    let startPoint = nodePosition(for: i, session: daySessions[i], in: nodeGeometry.size, allSessions: daySessions)
                                    let endPoint = nodePosition(for: i + 1, session: daySessions[i + 1], in: nodeGeometry.size, allSessions: daySessions)
                                    
                                    path.move(to: startPoint)
                                    path.addLine(to: endPoint)
                                }
                            }
                            .stroke(
                                colorScheme == .dark ?
                                Color.white.opacity(0.15) :
                                Color.black.opacity(0.1),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round)
                            )
                        }
                        
                        // Draw connection line from last session to draft node
                        if showDraftNode && daysOffset == 0 && !daySessions.isEmpty {
                            Path { path in
                                let lastSession = daySessions[daySessions.count - 1]
                                let lastPosition = nodePosition(for: daySessions.count - 1, session: lastSession, in: nodeGeometry.size, allSessions: daySessions)
                                let draftPos = draftNodePosition(in: nodeGeometry.size)
                                
                                path.move(to: lastPosition)
                                path.addLine(to: draftPos)
                            }
                            .stroke(
                                Color.green.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 5])
                            )
                            .transition(.opacity)
                        }
                        
                        // Draw session nodes (now tappable with highlight)
                        ForEach(Array(daySessions.enumerated()), id: \.element.id) { index, session in
                            let position = nodePosition(for: index, session: session, in: nodeGeometry.size, allSessions: daySessions)
                            let isSelected = selectedSessionId == session.id
                            
                            Button(action: {
                                onNodeTap(session, position)
                            }) {
                                ZStack {
                                    // Outer tap target (invisible)
                                    Circle()
                                        .fill(Color.clear)
                                        .frame(width: 32, height: 32)
                                    
                                    // Highlight ring for selected node
                                    if isSelected {
                                        Circle()
                                            .stroke(Color.blue, lineWidth: 2)
                                            .frame(width: 20, height: 20)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                    
                                    // Inner node
                                    Circle()
                                        .fill(
                                            isSelected ?
                                            Color.blue :
                                            (colorScheme == .dark ?
                                             Color.white.opacity(0.5) :
                                             Color.black.opacity(0.3))
                                        )
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .buttonStyle(.plain)
                            .position(position)
                        }
                        
                        // Draw draft node (pulsing animation)
                        if showDraftNode && daysOffset == 0 {
                            let draftPosition = draftNodePosition(in: nodeGeometry.size)
                            
                            ZStack {
                                // Pulsing outer ring
                                Circle()
                                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                                    .scaleEffect(pulseAnimation ? 1.8 : 1.0)
                                    .opacity(pulseAnimation ? 0.0 : 0.5)
                                
                                // Inner draft node
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                            .position(draftPosition)
                            .transition(.scale.combined(with: .opacity))
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                                    pulseAnimation = true
                                }
                            }
                            .onDisappear {
                                pulseAnimation = false
                            }
                        }
                        
                        // Draw message dots for selected session (using messageCount, no loading)
                        if let selectedId = selectedSessionId,
                           let selectedSession = daySessions.first(where: { $0.id == selectedId }),
                           let sessionIndex = daySessions.firstIndex(where: { $0.id == selectedId }) {
                            
                            let sessionPosition = nodePosition(for: sessionIndex, session: selectedSession, in: nodeGeometry.size, allSessions: daySessions)
                            
                            // Show simulated message dots based on messageCount
                            SimulatedMessageDotsOverlay(
                                messageCount: selectedSession.messageCount,
                                centerPosition: sessionPosition,
                                colorScheme: colorScheme
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .id(daysOffset)
                .transition(.asymmetric(
                    insertion: .move(edge: dragOffset > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: dragOffset > 0 ? .leading : .trailing).combined(with: .opacity)
                ))
                .offset(x: dragOffset)
                
                // Session count indicator - positioned at bottom with minimal padding
                if !daySessions.isEmpty || showDraftNode {
                    HStack {
                        if showDraftNode && daysOffset == 0 {
                            if daySessions.isEmpty {
                                Text("Draft in progress")
                                    .font(.caption2)
                                    .foregroundColor(.green.opacity(0.8))
                            } else {
                                Text("Draft + \(daySessions.count) session\(daySessions.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundColor(.green.opacity(0.8))
                            }
                        } else {
                            Text("\(daySessions.count) session\(daySessions.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                } else {
                    HStack {
                        Text("Swipe left or right")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 30)
                    .updating($isDragging) { value, state, transaction in
                        state = true
                    }
                    .onChanged { value in
                        let horizontalAmount = value.translation.width
                        let verticalAmount = abs(value.translation.height)
                        
                        if abs(horizontalAmount) > verticalAmount {
                            dragOffset = horizontalAmount
                        }
                    }
                    .onEnded { value in
                        let threshold: CGFloat = 50
                        let horizontalAmount = value.translation.width
                        let verticalAmount = abs(value.translation.height)
                        
                        if abs(horizontalAmount) > verticalAmount {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if abs(horizontalAmount) > threshold {
                                    if horizontalAmount > 0 {
                                        daysOffset += 1
                                    } else if daysOffset > 0 {
                                        daysOffset -= 1
                                    }
                                }
                                
                                dragOffset = 0
                            }
                        } else {
                            dragOffset = 0
                        }
                    }
            )
        }
        .onChange(of: showDraftNode) { oldValue, newValue in
            // Animate draft node appearance/disappearance
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                // State change will trigger draft node appearance
            }
        }
    }
    
    // Calculate position for draft node - improved to prevent off-screen placement
    private func draftNodePosition(in size: CGSize) -> CGPoint {
        if daySessions.isEmpty {
            // Center if no other sessions
            return CGPoint(x: size.width / 2, y: size.height / 2)
        } else {
            // Position after the last session with better bounds checking
            let lastSession = daySessions[daySessions.count - 1]
            let lastPosition = nodePosition(for: daySessions.count - 1, session: lastSession, in: size, allSessions: daySessions)
            
            // Calculate offset with bounds checking
            let paddingX: CGFloat = size.width * 0.15
            let maxX = size.width - paddingX
            let minX = paddingX
            
            let paddingY: CGFloat = size.height * 0.20
            let maxY = size.height - paddingY
            let minY = paddingY
            
            // Try to place to the right and slightly down
            var targetX = lastPosition.x + 60
            var targetY = lastPosition.y + 20
            
            // If too far right, wrap to left side but lower
            if targetX > maxX {
                targetX = minX + 40
                targetY = min(lastPosition.y + 60, maxY)
            }
            
            // Clamp to bounds
            targetX = max(minX, min(targetX, maxX))
            targetY = max(minY, min(targetY, maxY))
            
            return CGPoint(x: targetX, y: targetY)
        }
    }
    
    // Calculate position for each node - centered and better distributed
    private func nodePosition(for index: Int, session: ChatSession, in size: CGSize, allSessions: [ChatSession]) -> CGPoint {
        guard !allSessions.isEmpty else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        
        // Use more conservative padding to keep nodes centered
        let paddingX: CGFloat = size.width * 0.15
        let paddingY: CGFloat = size.height * 0.20
        let availableWidth = size.width - (paddingX * 2)
        let availableHeight = size.height - (paddingY * 2)
        
        if allSessions.count == 1 {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        
        // Parse session times
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        guard let sessionDate = formatter.date(from: session.updatedAt) else {
            return randomPosition(seed: session.id.hashValue, in: size, paddingX: paddingX, paddingY: paddingY)
        }
        
        // Get time range for the day's sessions
        let dates = allSessions.compactMap { formatter.date(from: $0.updatedAt) }
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            return randomPosition(seed: session.id.hashValue, in: size, paddingX: paddingX, paddingY: paddingY)
        }
        
        let timeRange = maxDate.timeIntervalSince(minDate)
        let timeProgress: CGFloat
        
        if timeRange > 0 {
            timeProgress = CGFloat(sessionDate.timeIntervalSince(minDate) / timeRange)
        } else {
            timeProgress = CGFloat(index) / CGFloat(allSessions.count - 1)
        }
        
        // Use session ID for consistent pseudo-random values
        let seed = abs(session.id.hashValue)
        let random1 = sin(Double(seed))
        let random2 = cos(Double(seed) * 1.5)
        let random3 = sin(Double(seed) * 2.3)
        
        // Create time-based clusters with centered distribution
        let clusterCount: CGFloat = 4
        let clusterIndex = floor(timeProgress * clusterCount)
        
        // Base position on cluster center - keep more centered vertically
        let clusterCenterX = (clusterIndex + 0.5) / clusterCount
        let clusterCenterY: CGFloat = 0.5 // Keep at vertical center
        
        // Reduce spread to keep nodes more centered
        let clusterSpreadX: CGFloat = 0.15
        let clusterSpreadY: CGFloat = 0.25
        
        let offsetX = (random1 * 0.5 + 0.5) * clusterSpreadX - (clusterSpreadX / 2)
        let offsetY = (random2 * 0.5 + 0.5) * clusterSpreadY - (clusterSpreadY / 2)
        
        // Add micro-variation
        let microOffsetX = (random3 * 0.5 + 0.5) * 0.03 - 0.015
        let microOffsetY = (sin(random3 * 3) * 0.5 + 0.5) * 0.03 - 0.015
        
        // Calculate final position
        let xProgress = clusterCenterX + offsetX + microOffsetX
        let yProgress = clusterCenterY + offsetY + microOffsetY
        
        // Clamp to bounds
        let x = paddingX + (availableWidth * min(max(xProgress, 0), 1))
        let y = paddingY + (availableHeight * min(max(yProgress, 0), 1))
        
        return CGPoint(x: x, y: y)
    }
    
    // Fallback random position
    private func randomPosition(seed: Int, in size: CGSize, paddingX: CGFloat, paddingY: CGFloat) -> CGPoint {
        let random1 = sin(Double(seed)) * 0.5 + 0.5
        let random2 = cos(Double(seed) * 1.5) * 0.5 + 0.5
        
        let x = paddingX + (size.width - paddingX * 2) * CGFloat(random1)
        let y = paddingY + (size.height - paddingY * 2) * CGFloat(random2)
        
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Simulated Message Dots Overlay (no message loading, just uses messageCount)
struct SimulatedMessageDotsOverlay: View {
    let messageCount: Int
    let centerPosition: CGPoint
    let colorScheme: ColorScheme
    
    // Calculate how many dots to show based on message count
    private var displayedDotCount: Int {
        if messageCount <= 20 {
            return messageCount
        } else if messageCount <= 50 {
            return messageCount / 2
        } else {
            return min(25, messageCount / 3)
        }
    }
    
    var body: some View {
        ZStack {
            // Draw connecting lines between dots
            if displayedDotCount > 1 {
                Path { path in
                    for i in 0..<(displayedDotCount - 1) {
                        let startPos = dotPosition(for: i)
                        let endPos = dotPosition(for: i + 1)
                        
                        path.move(to: startPos)
                        path.addLine(to: endPos)
                    }
                }
                .stroke(
                    Color.blue.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round)
                )
            }
            
            // Draw message dots
            ForEach(0..<displayedDotCount, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 4, height: 4)
                    .position(dotPosition(for: index))
            }
        }
    }
    
    // Calculate position for each dot in a circle around the session node
    private func dotPosition(for index: Int) -> CGPoint {
        let radius: CGFloat = 30
        let angleStep = (2 * .pi) / CGFloat(displayedDotCount)
        let angle = angleStep * CGFloat(index) - (.pi / 2) // Start from top
        
        let x = centerPosition.x + radius * cos(angle)
        let y = centerPosition.y + radius * sin(angle)
        
        return CGPoint(x: x, y: y)
    }
    
    // Simulate alternating user/assistant pattern for dots
    private func dotColor(for index: Int) -> Color {
        // Simulate a pattern: user, assistant, user, assistant, etc with occasional system
        if index % 7 == 6 {
            // Every 7th message is "system"
            return Color.gray.opacity(0.6)
        } else if index % 2 == 0 {
            // Even indices are "user"
            return Color.blue.opacity(0.8)
        } else {
            // Odd indices are "assistant"
            return colorScheme == .dark ?
                Color.white.opacity(0.6) :
                Color.black.opacity(0.4)
        }
    }
}

#Preview {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    
    let calendar = Calendar.current
    let now = Date()
    
    func dateString(daysAgo: Int, hoursAgo: Int, minutesOffset: Int = 0) -> String {
        var date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        date = calendar.date(byAdding: .hour, value: -hoursAgo, to: date)!
        date = calendar.date(byAdding: .minute, value: minutesOffset, to: date)!
        return formatter.string(from: date)
    }
    
    return ZStack {
        Color(UIColor.systemBackground)
            .ignoresSafeArea()
        
        NodeMatrix(
            sessions: [
                // Today
                ChatSession(id: "1", name: "Early Morning", messageCount: 5, createdAt: dateString(daysAgo: 0, hoursAgo: 8), updatedAt: dateString(daysAgo: 0, hoursAgo: 8)),
                ChatSession(id: "2", name: "Morning", messageCount: 12, createdAt: dateString(daysAgo: 0, hoursAgo: 7, minutesOffset: 30), updatedAt: dateString(daysAgo: 0, hoursAgo: 7, minutesOffset: 30)),
                ChatSession(id: "3", name: "Late Morning", messageCount: 8, createdAt: dateString(daysAgo: 0, hoursAgo: 7), updatedAt: dateString(daysAgo: 0, hoursAgo: 7)),
            ],
            selectedSessionId: "2",
            onNodeTap: { session, position in
                print("Tapped session: \(session.name) at position: \(position)")
            },
            showDraftNode: true
        )
        .frame(height: 400)
    }
}

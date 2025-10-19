import SwiftUI

// MARK: - Node Data Structures

/// Precomputed node position data to avoid recalculation
struct NodePositionData: Identifiable, Equatable {
    let id: String
    let session: ChatSession
    let position: CGPoint
    
    static func == (lhs: NodePositionData, rhs: NodePositionData) -> Bool {
        lhs.id == rhs.id && lhs.position == rhs.position
    }
}

// MARK: - Connection Lines View (Optimized with Equatable)

/// Renders connection lines between nodes - uses Equatable to prevent unnecessary redraws
struct ConnectionLinesView: View, Equatable {
    let nodePositions: [CGPoint]
    let colorScheme: ColorScheme
    
    static func == (lhs: ConnectionLinesView, rhs: ConnectionLinesView) -> Bool {
        lhs.nodePositions == rhs.nodePositions && lhs.colorScheme == rhs.colorScheme
    }
    
    var body: some View {
        Path { path in
            for i in 0..<(nodePositions.count - 1) {
                path.move(to: nodePositions[i])
                path.addLine(to: nodePositions[i + 1])
            }
        }
        .stroke(
            colorScheme == .dark ?
            Color.white.opacity(0.15) :
            Color.black.opacity(0.1),
            style: StrokeStyle(lineWidth: 1, lineCap: .round)
        )
    }
}

// MARK: - Draft Connection Line View (Optimized with Equatable)

/// Renders dashed line to draft node - uses Equatable to prevent unnecessary redraws
struct DraftConnectionLineView: View, Equatable {
    let startPosition: CGPoint
    let endPosition: CGPoint
    
    static func == (lhs: DraftConnectionLineView, rhs: DraftConnectionLineView) -> Bool {
        lhs.startPosition == rhs.startPosition && lhs.endPosition == rhs.endPosition
    }
    
    var body: some View {
        Path { path in
            path.move(to: startPosition)
            path.addLine(to: endPosition)
        }
        .stroke(
            Color.green.opacity(0.3),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 5])
        )
    }
}

// MARK: - Session Node View (Optimized)

/// Single session node - optimized to only redraw when selection state changes
struct SessionNodeView: View {
    let session: ChatSession
    let position: CGPoint
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
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
}

// MARK: - Message Dots Overlay (Optimized with Equatable)

/// Renders message dots around a selected session - uses Equatable to prevent redraw
struct OptimizedMessageDotsOverlay: View, Equatable {
    let messageCount: Int
    let centerPosition: CGPoint
    let colorScheme: ColorScheme
    
    // Precompute dot count
    private var displayedDotCount: Int {
        if messageCount <= 20 {
            return messageCount
        } else if messageCount <= 50 {
            return messageCount / 2
        } else {
            return min(25, messageCount / 3)
        }
    }
    
    // Precompute all dot positions
    private var dotPositions: [CGPoint] {
        let radius: CGFloat = 30
        let angleStep = (2 * .pi) / CGFloat(displayedDotCount)
        
        return (0..<displayedDotCount).map { index in
            let angle = angleStep * CGFloat(index) - (.pi / 2)
            return CGPoint(
                x: centerPosition.x + radius * cos(angle),
                y: centerPosition.y + radius * sin(angle)
            )
        }
    }
    
    static func == (lhs: OptimizedMessageDotsOverlay, rhs: OptimizedMessageDotsOverlay) -> Bool {
        lhs.messageCount == rhs.messageCount &&
        lhs.centerPosition == rhs.centerPosition &&
        lhs.colorScheme == rhs.colorScheme
    }
    
    var body: some View {
        let positions = dotPositions
        
        ZStack {
            // Draw connecting lines
            if positions.count > 1 {
                Path { path in
                    for i in 0..<(positions.count - 1) {
                        path.move(to: positions[i])
                        path.addLine(to: positions[i + 1])
                    }
                }
                .stroke(
                    Color.blue.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round)
                )
            }
            
            // Draw dots
            ForEach(0..<positions.count, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 4, height: 4)
                    .position(positions[index])
            }
        }
    }
    
    private func dotColor(for index: Int) -> Color {
        if index % 7 == 6 {
            return Color.gray.opacity(0.6)
        } else if index % 2 == 0 {
            return Color.blue.opacity(0.8)
        } else {
            return colorScheme == .dark ?
                Color.white.opacity(0.6) :
                Color.black.opacity(0.4)
        }
    }
}

// MARK: - Main NodeMatrix View

struct NodeMatrix: View {
    let sessions: [ChatSession]
    let selectedSessionId: String?
    let onNodeTap: (ChatSession, CGPoint) -> Void
    var showDraftNode: Bool = false
    @Environment(\.colorScheme) var colorScheme
    @State private var daysOffset: Int = 0
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging: Bool = false
    @State private var pulseAnimation = false
    
    // PERFORMANCE: Cache geometry size to detect when recalculation is needed
    @State private var cachedSize: CGSize = .zero
    @State private var cachedNodePositions: [NodePositionData] = []
    @State private var cachedDraftPosition: CGPoint = .zero
    
    private var targetDate: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -daysOffset, to: Date()) ?? Date()
    }
    
    private var daySessions: [ChatSession] {
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        let filtered = sessions.filter { session in
            guard let sessionDate = formatter.date(from: session.updatedAt) else {
                return false
            }
            return calendar.isDate(sessionDate, inSameDayAs: targetDate)
        }
        
        return filtered.sorted { session1, session2 in
            guard let date1 = formatter.date(from: session1.updatedAt),
                  let date2 = formatter.date(from: session2.updatedAt) else {
                return false
            }
            return date1 < date2
        }
    }
    
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
                // Date label header
                HStack {
                    HStack(spacing: 8) {
                        Text(dateLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                        
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
                
                // Node content area
                GeometryReader { nodeGeometry in
                    ZStack {
                        // Empty state
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
                        
                        // Connection lines (optimized with Equatable)
                        if cachedNodePositions.count > 1 {
                            ConnectionLinesView(
                                nodePositions: cachedNodePositions.map { $0.position },
                                colorScheme: colorScheme
                            )
                            .equatable()
                        }
                        
                        // Draft connection line
                        if showDraftNode && daysOffset == 0 && !cachedNodePositions.isEmpty {
                            DraftConnectionLineView(
                                startPosition: cachedNodePositions.last!.position,
                                endPosition: cachedDraftPosition
                            )
                            .equatable()
                        }
                        
                        // Session nodes
                        ForEach(cachedNodePositions) { nodeData in
                            SessionNodeView(
                                session: nodeData.session,
                                position: nodeData.position,
                                isSelected: selectedSessionId == nodeData.id,
                                colorScheme: colorScheme,
                                onTap: {
                                    onNodeTap(nodeData.session, nodeData.position)
                                }
                            )
                            // Use id to force recreation only when position changes
                            .id("\(nodeData.id)-\(nodeData.position.x)-\(nodeData.position.y)")
                        }
                        
                        // Draft node (pulsing animation)
                        if showDraftNode && daysOffset == 0 {
                            ZStack {
                                Circle()
                                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                                    .scaleEffect(pulseAnimation ? 1.8 : 1.0)
                                    .opacity(pulseAnimation ? 0.0 : 0.5)
                                
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                            .position(cachedDraftPosition)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                                    pulseAnimation = true
                                }
                            }
                            .onDisappear {
                                pulseAnimation = false
                            }
                        }
                        
                        // Message dots overlay (optimized with Equatable)
                        if let selectedId = selectedSessionId,
                           let nodeData = cachedNodePositions.first(where: { $0.id == selectedId }) {
                            OptimizedMessageDotsOverlay(
                                messageCount: nodeData.session.messageCount,
                                centerPosition: nodeData.position,
                                colorScheme: colorScheme
                            )
                            .equatable()
                        }
                    }
                    .onAppear {
                        // Initialize cache on appear
                        updateCacheIfNeeded(size: nodeGeometry.size, sessions: daySessions)
                    }
                    .onChange(of: nodeGeometry.size) { _, newSize in
                        // Update cache when size changes
                        updateCacheIfNeeded(size: newSize, sessions: daySessions)
                    }
                    .onChange(of: daySessions) { _, newSessions in  
                        // Update cache when sessions change
                        updateCacheIfNeeded(size: nodeGeometry.size, sessions: newSessions)
                    }
                }
                .padding(.horizontal, 16)
                .id(daysOffset)
                .transition(.asymmetric(
                    insertion: .move(edge: dragOffset > 0 ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: dragOffset > 0 ? .leading : .trailing).combined(with: .opacity)
                ))
                .offset(x: dragOffset)
                
                // Session count indicator
                HStack {
                    if !daySessions.isEmpty || showDraftNode {
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
                    } else {
                        Text("Swipe left or right")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
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
    }
    
    // PERFORMANCE: Update cache only when needed
    private func updateCacheIfNeeded(size: CGSize, sessions: [ChatSession]) {
        // Check if we need to recalculate
        let needsUpdate = cachedSize != size ||
                         cachedNodePositions.count != sessions.count ||
                         zip(cachedNodePositions, sessions).contains { $0.0.id != $0.1.id }
        
        guard needsUpdate else { return }
        
        // Recalculate positions
        cachedSize = size
        cachedNodePositions = sessions.enumerated().map { index, session in
            NodePositionData(
                id: session.id,
                session: session,
                position: calculateNodePosition(for: index, session: session, in: size, allSessions: sessions)
            )
        }
        cachedDraftPosition = calculateDraftPosition(in: size, sessions: sessions)
    }
    
    private func calculateDraftPosition(in size: CGSize, sessions: [ChatSession]) -> CGPoint {
        if sessions.isEmpty {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        } else {
            let lastPosition = cachedNodePositions.last?.position ?? CGPoint(x: size.width / 2, y: size.height / 2)
            
            let paddingX: CGFloat = size.width * 0.15
            let maxX = size.width - paddingX
            let minX = paddingX
            let paddingY: CGFloat = size.height * 0.20
            let maxY = size.height - paddingY
            let minY = paddingY
            
            var targetX = lastPosition.x + 60
            var targetY = lastPosition.y + 20
            
            if targetX > maxX {
                targetX = minX + 40
                targetY = min(lastPosition.y + 60, maxY)
            }
            
            targetX = max(minX, min(targetX, maxX))
            targetY = max(minY, min(targetY, maxY))
            
            return CGPoint(x: targetX, y: targetY)
        }
    }
    
    private func calculateNodePosition(for index: Int, session: ChatSession, in size: CGSize, allSessions: [ChatSession]) -> CGPoint {
        guard !allSessions.isEmpty else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        
        let paddingX: CGFloat = size.width * 0.15
        let paddingY: CGFloat = size.height * 0.20
        let availableWidth = size.width - (paddingX * 2)
        let availableHeight = size.height - (paddingY * 2)
        
        if allSessions.count == 1 {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        guard let sessionDate = formatter.date(from: session.updatedAt) else {
            return randomPosition(seed: session.id.hashValue, in: size, paddingX: paddingX, paddingY: paddingY)
        }
        
        let dates = allSessions.compactMap { formatter.date(from: $0.updatedAt) }
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            return randomPosition(seed: session.id.hashValue, in: size, paddingX: paddingX, paddingY: paddingY)
        }
        
        let timeRange = maxDate.timeIntervalSince(minDate)
        let timeProgress: CGFloat = timeRange > 0 ?
            CGFloat(sessionDate.timeIntervalSince(minDate) / timeRange) :
            CGFloat(index) / CGFloat(allSessions.count - 1)
        
        let seed = abs(session.id.hashValue)
        let random1 = sin(Double(seed))
        let random2 = cos(Double(seed) * 1.5)
        let random3 = sin(Double(seed) * 2.3)
        
        let clusterCount: CGFloat = 4
        let clusterIndex = floor(timeProgress * clusterCount)
        let clusterCenterX = (clusterIndex + 0.5) / clusterCount
        let clusterCenterY: CGFloat = 0.5
        
        let clusterSpreadX: CGFloat = 0.15
        let clusterSpreadY: CGFloat = 0.25
        
        let offsetX = (random1 * 0.5 + 0.5) * clusterSpreadX - (clusterSpreadX / 2)
        let offsetY = (random2 * 0.5 + 0.5) * clusterSpreadY - (clusterSpreadY / 2)
        
        let microOffsetX = (random3 * 0.5 + 0.5) * 0.03 - 0.015
        let microOffsetY = (sin(random3 * 3) * 0.5 + 0.5) * 0.03 - 0.015
        
        let xProgress = clusterCenterX + offsetX + microOffsetX
        let yProgress = clusterCenterY + offsetY + microOffsetY
        
        let x = paddingX + (availableWidth * min(max(xProgress, 0), 1))
        let y = paddingY + (availableHeight * min(max(yProgress, 0), 1))
        
        return CGPoint(x: x, y: y)
    }
    
    private func randomPosition(seed: Int, in size: CGSize, paddingX: CGFloat, paddingY: CGFloat) -> CGPoint {
        let random1 = sin(Double(seed)) * 0.5 + 0.5
        let random2 = cos(Double(seed) * 1.5) * 0.5 + 0.5
        
        let x = paddingX + (size.width - paddingX * 2) * CGFloat(random1)
        let y = paddingY + (size.height - paddingY * 2) * CGFloat(random2)
        
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Preview

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
                ChatSession(id: "1", description: "Early Morning", messageCount: 5, createdAt: dateString(daysAgo: 0, hoursAgo: 8), updatedAt: dateString(daysAgo: 0, hoursAgo: 8)),
                ChatSession(id: "2", description: "Morning", messageCount: 12, createdAt: dateString(daysAgo: 0, hoursAgo: 7, minutesOffset: 30), updatedAt: dateString(daysAgo: 0, hoursAgo: 7, minutesOffset: 30)),
                ChatSession(id: "3", description: "Late Morning", messageCount: 8, createdAt: dateString(daysAgo: 0, hoursAgo: 7), updatedAt: dateString(daysAgo: 0, hoursAgo: 7)),
            ],
            selectedSessionId: "2",
            onNodeTap: { session, position in
                print("Tapped session: \(session.description) at position: \(position)")
            },
            showDraftNode: true
        )
        .frame(height: 400)
    }
}

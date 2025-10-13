import SwiftUI
import Markdown

struct MessageBubbleView: View {
    let message: Message
    let completedTasks: [CompletedToolCall]
    @State private var showFullText = false
    @State private var isTruncated = false
    
    // Maximum height for truncation - about 70% of screen like PR #11
    private let maxHeight: CGFloat = UIScreen.main.bounds.height * 0.7
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Message content - filter out tool responses AND tool requests (we'll show them as pills)
            let filteredContent = message.content.filter { 
                !isToolResponse($0) && !isToolRequest($0)
            }
            
            if !filteredContent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(filteredContent.enumerated()), id: \.offset) { index, content in
                        TruncatableMessageContentView(
                            content: content,
                            maxHeight: maxHeight,
                            showFullText: $showFullText,
                            isTruncated: $isTruncated,
                            isUserMessage: message.role == .user
                        )
                    }
                }
            }
            
            // Show consolidated task completion pill if there are completed tasks (PR #11 style)
            if !completedTasks.isEmpty {
                // Show all completed tools as collapsible items (they were actually expandable in PR #11)
                ForEach(completedTasks, id: \.toolCall.name) { completedTask in
                    CompletedToolPillView(completedCall: completedTask)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showFullText) {
            FullTextOverlay(content: message.content.filter { !isToolResponse($0) })
        }
    }
    
    private func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) // Convert from milliseconds
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func isToolResponse(_ content: MessageContent) -> Bool {
        if case .toolResponse = content {
            return true
        }
        return false
    }
    
    private func isToolRequest(_ content: MessageContent) -> Bool {
        if case .toolRequest = content {
            return true
        }
        return false
    }
}

struct MessageContentView: View {
    let content: MessageContent
    
    var body: some View {
        switch content {
        case .text(let textContent):
            MarkdownText(text: textContent.text)
                .textSelection(.enabled)
            
        case .toolRequest(let toolContent):
            ToolRequestView(toolContent: toolContent)
            
        case .toolResponse(_):
            // Hide tool responses - user doesn't want to see them
            EmptyView()
            
        case .toolConfirmationRequest(let toolContent):
            ToolConfirmationView(toolContent: toolContent)
            
        case .summarizationRequested(_):
            // Hide summarization requests for now
            EmptyView()
        }
    }
}

// MARK: - Markdown Parsing Helper
private struct MarkdownParser {
    static func parse(_ text: String) -> AttributedString {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = Document(parsing: trimmedText)
        
        var attributedString = AttributedString()
        for child in document.children {
            attributedString.append(processElement(child))
        }
        
        return attributedString.characters.isEmpty ? AttributedString(trimmedText) : attributedString
    }
    
    private static func processElement(_ element: Markup) -> AttributedString {
        var result = AttributedString()
        
        switch element {
        case let paragraph as Paragraph:
            for child in paragraph.children {
                if let inlineChild = child as? InlineMarkup {
                    result.append(processInline(inlineChild))
                }
            }
            result.append(AttributedString("\n"))
            
        case let heading as Heading:
            var headingText = AttributedString()
            for child in heading.children {
                if let inlineChild = child as? InlineMarkup {
                    headingText.append(processInline(inlineChild))
                }
            }
            headingText.font = .system(size: max(20 - CGFloat(heading.level) * 2, 14), weight: .bold)
            result.append(headingText)
            result.append(AttributedString("\n"))
            
        case let codeBlock as CodeBlock:
            var codeText = AttributedString(codeBlock.code)
            codeText.font = .monospaced(.body)()
            codeText.backgroundColor = .secondary.opacity(0.1)
            result.append(codeText)
            result.append(AttributedString("\n"))
            
        case let listItem as ListItem:
            result.append(AttributedString("• "))
            for child in listItem.children {
                result.append(processElement(child))
            }
            
        default:
            if let blockElement = element as? BlockMarkup {
                for child in blockElement.children {
                    result.append(processElement(child))
                }
            }
        }
        
        return result
    }
    
    private static func processInline(_ element: InlineMarkup) -> AttributedString {
        switch element {
        case let text as Markdown.Text:
            return AttributedString(text.plainText)
            
        case let strong as Strong:
            var strongText = AttributedString()
            for child in strong.children {
                if let inlineChild = child as? InlineMarkup {
                    strongText.append(processInline(inlineChild))
                }
            }
            strongText.font = .body.bold()
            return strongText
            
        case let emphasis as Emphasis:
            var emphasisText = AttributedString()
            for child in emphasis.children {
                if let inlineChild = child as? InlineMarkup {
                    emphasisText.append(processInline(inlineChild))
                }
            }
            emphasisText.font = .body.italic()
            return emphasisText
            
        case let inlineCode as InlineCode:
            var codeText = AttributedString(inlineCode.code)
            codeText.font = .monospaced(.body)()
            codeText.backgroundColor = .secondary.opacity(0.1)
            return codeText
            
        case let link as Markdown.Link:
            var linkText = AttributedString()
            for child in link.children {
                if let inlineChild = child as? InlineMarkup {
                    linkText.append(processInline(inlineChild))
                }
            }
            linkText.foregroundColor = .blue
            linkText.underlineStyle = .single
            if let destination = link.destination {
                linkText.link = URL(string: destination)
            }
            return linkText
            
        default:
            return AttributedString(element.plainText)
        }
    }
}

// MARK: - Cached Markdown Text View
struct MarkdownText: View {
    let text: String
    var isUserMessage: Bool = false
    @State private var cachedAttributedText: AttributedString?
    @State private var previousText = ""
    
    var body: some View {
        Text(cachedAttributedText ?? AttributedString(text))
            .font(.system(size: 16, weight: isUserMessage ? .bold : .regular))
            .textSelection(.enabled)
            .onAppear {
                if cachedAttributedText == nil {
                    cachedAttributedText = MarkdownParser.parse(text)
                    previousText = text
                }
            }
            .onChange(of: text) { newText in
                // Only reparse if text changed significantly
                if !newText.hasPrefix(previousText) || newText.count - previousText.count > 50 {
                    // Full reparse for significant changes
                    cachedAttributedText = MarkdownParser.parse(newText)
                } else if newText != previousText {
                    // For streaming: just append the new part efficiently
                    if let cached = cachedAttributedText {
                        let newPart = String(newText.dropFirst(previousText.count))
                        // Try to append without full reparse for efficiency
                        cachedAttributedText = cached + AttributedString(newPart)
                    } else {
                        cachedAttributedText = MarkdownParser.parse(newText)
                    }
                }
                previousText = newText
            }
    }
}

// MARK: - Tool Views
struct CollapsibleToolRequestView: View {
    let toolContent: ToolRequestContent
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundColor(.orange)
                        .font(.caption)
                    
                    Text("Tool: \(toolContent.toolCall.name)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    if !isExpanded && !toolContent.toolCall.arguments.isEmpty {
                        Text("(\(toolContent.toolCall.arguments.count) args)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded && !toolContent.toolCall.arguments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .padding(.horizontal, 8)
                    
                    Text("Arguments:")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    
                    ForEach(Array(toolContent.toolCall.arguments.keys.sorted()), id: \.self) { key in
                        HStack(alignment: .top) {
                            Text("\(key):")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                                .frame(minWidth: 60, alignment: .trailing)
                            
                            Text("\(String(describing: toolContent.toolCall.arguments[key]?.value))")
                                .font(.caption2)
                                .foregroundColor(.primary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// Keep original for compatibility if needed
struct ToolRequestView: View {
    let toolContent: ToolRequestContent
    
    var body: some View {
        CollapsibleToolRequestView(toolContent: toolContent)
    }
}

struct ToolResponseView: View {
    let toolContent: ToolResponseContent
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: toolContent.toolResult.status == "success" ? "checkmark.circle" : "xmark.circle")
                    .foregroundColor(toolContent.toolResult.status == "success" ? .green : .red)
                Text("Tool Response")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            
            if let error = toolContent.toolResult.error {
                Text("Error: \(error)")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            
            if let value = toolContent.toolResult.value {
                Text("Result: \(String(describing: value.value))")
                    .font(.caption2)
                    .foregroundColor(.primary)
            }
        }
        .padding(8)
        .background((toolContent.toolResult.status == "success" ? Color.green : Color.red).opacity(0.1))
        .cornerRadius(8)
    }
}

struct CollapsibleToolConfirmationView: View {
    let toolContent: ToolConfirmationRequestContent
    @State private var isExpanded: Bool = true // Start expanded for permission requests
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.blue)
                        .font(.caption)
                    
                    Text("Permission: \(toolContent.toolName)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    if !isExpanded {
                        Text("(action required)")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    
                    Spacer()
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .padding(.horizontal, 8)
                    
                    Text("Allow \(toolContent.toolName)?")
                        .font(.body)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    
                    if !toolContent.arguments.isEmpty {
                        Text("Arguments:")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                        
                        ForEach(Array(toolContent.arguments.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text("\(key):")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                    .frame(minWidth: 60, alignment: .trailing)
                                
                                Text("\(String(describing: toolContent.arguments[key]?.value))")
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Button("Deny") {
                            // TODO: Implement permission response
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                        
                        Button("Allow Once") {
                            // TODO: Implement permission response
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Always Allow") {
                            // TODO: Implement permission response
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// Keep original for compatibility if needed
struct ToolConfirmationView: View {
    let toolContent: ToolConfirmationRequestContent
    
    var body: some View {
        CollapsibleToolConfirmationView(toolContent: toolContent)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            // Basic message examples
            MessageBubbleView(message: Message(role: .user, text: "Hello, can you help me with **markdown** and `code`?"), completedTasks: [])
            MessageBubbleView(message: Message(role: .assistant, text: "Sure! I can help you with **bold text**, `inline code`, and other formatting."), completedTasks: [])
            
            // Comprehensive markdown test examples
            MessageBubbleView(message: Message(role: .assistant, text: """
# Markdown Test

Here are various **formatting** examples:

## Text Styles
- **Bold text**
- *Italic text* 
- `Inline code`
- ***Bold and italic***

## Code Block
```swift
func testFunction() {
    print("Hello World")
}
```

## Links
Visit [Apple](https://apple.com) for more info.

## Lists
• First item
• Second **bold** item
• Third `code` item

*This tests comprehensive markdown rendering.*
"""), completedTasks: [])
            
            MessageBubbleView(message: Message(role: .user, text: """
Testing more complex markdown:

### Headings Work?
#### Smaller Heading
##### Even Smaller

Mixed content: **bold** with *italic* and `code` plus [links](https://github.com).

```python
# Code blocks with different languages
def hello_world():
    return "Hello from Python!"
```

**Note**: This should all render properly.
"""), completedTasks: [])
        }
        .padding()
    }
}

// MARK: - Completed Tool Pill View (PR #11 style - expandable)
struct CompletedToolPillView: View {
    let completedCall: CompletedToolCall
    @State private var isExpanded: Bool = false
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text(completedCall.toolCall.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGray6).opacity(0.85))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        
        if isExpanded {
            VStack(alignment: .leading, spacing: 8) {
                // Show tool details
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(completedCall.result.status)
                            .font(.caption)
                            .foregroundColor(completedCall.result.status == "success" ? .green : .red)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Text(String(format: "%.2fs", completedCall.duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if !completedCall.toolCall.arguments.isEmpty {
                        Text("Arguments:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        
                        ForEach(Array(completedCall.toolCall.arguments.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .top, spacing: 4) {
                                Text("\(key):")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                let valueString = String(describing: completedCall.toolCall.arguments[key]?.value ?? "")
                                Text(valueString.count > 100 ? String(valueString.prefix(100)) + "..." : valueString)
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    
                    if let error = completedCall.result.error {
                        Text("Error:")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 4)
                        Text(error.count > 200 ? String(error.prefix(200)) + "..." : error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .lineLimit(3)
                    } else if let value = completedCall.result.value {
                        Text("Result:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        let valueString = String(describing: value.value)
                        Text(valueString.count > 200 ? String(valueString.prefix(200)) + "..." : valueString)
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .lineLimit(5)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemGray6).opacity(0.3))
                .cornerRadius(12)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Tool Call Progress View
struct ToolCallProgressView: View {
    let toolCall: ToolCall
    
    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolCall.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    if let firstArgument = getFirstArgument() {
                        Text(firstArgument)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            )
            
            Text("executing...")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.6)
    }
    
    private func getFirstArgument() -> String? {
        guard let firstKey = toolCall.arguments.keys.sorted().first,
              let firstValue = toolCall.arguments[firstKey] else {
            return nil
        }
        
        let valueString = String(describing: firstValue.value)
        // Truncate if too long
        return valueString.count > 50 ? String(valueString.prefix(50)) + "..." : valueString
    }
}

// MARK: - Completed Tool Call View
struct CollapsibleToolCallView: View {
    let completedCall: CompletedToolCall
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    Image(systemName: completedCall.result.status == "success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(completedCall.result.status == "success" ? .green : .red)
                        .font(.caption)
                    
                    Text(completedCall.toolCall.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(String(format: "%.2fs", completedCall.duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(completedCall.result.status)
                        .font(.caption2)
                        .foregroundColor(completedCall.result.status == "success" ? .green : .red)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(completedCall.result.status == "success" ? Color.green.opacity(0.2) : Color.red.opacity(0.2), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let firstArgument = getFirstArgument() {
                        Text("Arguments:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        
                        Text(firstArgument)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(.systemGray5))
                            )
                    }
                    
                    if completedCall.result.status == "error", let error = completedCall.result.error {
                        Text("Error:")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .padding(.top, 4)
                        
                        Text(error.count > 200 ? String(error.prefix(200)) + "..." : error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(nil)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red.opacity(0.1))
                            )
                    } else if let value = completedCall.result.value {
                        Text("Result:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        
                        let valueString = String(describing: value.value)
                        Text(valueString.count > 200 ? String(valueString.prefix(200)) + "..." : valueString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(.systemGray5))
                            )
                    }
                    
                    Text(formatCompletionTime(completedCall.completedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
    }
    
    private func getFirstArgument() -> String? {
        guard !completedCall.toolCall.arguments.isEmpty else { return nil }
        
        var argumentStrings: [String] = []
        for (key, value) in completedCall.toolCall.arguments.sorted(by: { $0.key < $1.key }) {
            let valueString = String(describing: value.value)
            argumentStrings.append("\(key): \(valueString)")
        }
        
        let combined = argumentStrings.joined(separator: "\n")
        return combined.count > 500 ? String(combined.prefix(500)) + "..." : combined
    }
    
    private func formatCompletionTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "completed \(formatter.string(from: date))"
    }
}

struct CompletedToolCallView: View {
    let completedCall: CompletedToolCall
    
    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: completedCall.result.status == "success" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(completedCall.result.status == "success" ? .green : .red)
                    .font(.caption)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(completedCall.toolCall.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    if let firstArgument = getFirstArgument() {
                        Text(firstArgument)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    
                    HStack(spacing: 4) {
                        Text(String(format: "%.2fs", completedCall.duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(completedCall.result.status)
                            .font(.caption2)
                            .foregroundColor(completedCall.result.status == "success" ? .green : .red)
                            .fontWeight(.medium)
                    }
                }
                
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(completedCall.result.status == "success" ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                    )
            )
            
            Text(formatCompletionTime(completedCall.completedAt))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.6)
    }
    
    private func getFirstArgument() -> String? {
        guard let firstKey = completedCall.toolCall.arguments.keys.sorted().first,
              let firstValue = completedCall.toolCall.arguments[firstKey] else {
            return nil
        }
        
        let valueString = String(describing: firstValue.value)
        // Truncate if too long
        return valueString.count > 50 ? String(valueString.prefix(50)) + "..." : valueString
    }
    
    private func formatCompletionTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "completed \(formatter.string(from: date))"
    }
}

// MARK: - Truncatable Message Content View
struct TruncatableMessageContentView: View {
    let content: MessageContent
    let maxHeight: CGFloat
    @Binding var showFullText: Bool
    @Binding var isTruncated: Bool
    let isUserMessage: Bool
    
    var body: some View {
        switch content {
        case .text(let textContent):
            // Use MarkdownText for proper markdown rendering  
            MarkdownText(text: textContent.text, isUserMessage: isUserMessage)
                .lineSpacing(8)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
        case .toolRequest(_):
            // Hide tool requests - they'll be shown as consolidated pills
            EmptyView()
            
        case .toolResponse(_):
            // Hide tool responses - user doesn't want to see them
            EmptyView()
            
        case .toolConfirmationRequest(let toolContent):
            ToolConfirmationView(toolContent: toolContent)
            
        case .summarizationRequested(_):
            // Hide summarization requests for now
            EmptyView()
        }
    }
}

// MARK: - Truncatable Markdown Text View
struct TruncatableMarkdownText: View {
    let text: String
    let maxHeight: CGFloat
    @Binding var isTruncated: Bool
    @State private var fullHeight: CGFloat = 0
    @State private var displayText: String = ""
    
    // Configuration for smart truncation
    private let maxPreviewLines = 8  // Show more lines (6-8 depending on content)
    private let showLastLines = true // Show last lines instead of first
    
    var body: some View {
        Text(parseMarkdown(displayText.isEmpty ? text : displayText))
            .textSelection(.enabled)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            fullHeight = geometry.size.height
                            updateTruncation()
                        }
                        .onChange(of: geometry.size.height) {
                            fullHeight = geometry.size.height
                            updateTruncation()
                        }
                        .onChange(of: text) {
                            updateTruncation()
                        }
                }
            )
            .overlay(
                // Show indicator if truncated
                Group {
                    if isTruncated {
                        VStack {
                            // Show fade from top since we're showing last lines
                            if showLastLines {
                                LinearGradient(
                                    gradient: Gradient(colors: [Color(.systemGray6).opacity(0.9), Color.clear]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 30)
                                .overlay(
                                    Text("Tap to see more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 6),
                                    alignment: .top
                                )
                                
                                Spacer()
                            } else {
                                // Original bottom fade for first lines
                                Spacer()
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.clear, Color(.systemGray6)]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 30)
                                .overlay(
                                    Text("Tap to expand")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.bottom, 4),
                                    alignment: .bottom
                                )
                            }
                        }
                    }
                }
            )
    }
    
    private func updateTruncation() {
        // Split text into lines for smarter truncation
        let lines = text.components(separatedBy: .newlines)
        
        // If text is short enough, show everything
        if lines.count <= maxPreviewLines || fullHeight <= maxHeight {
            displayText = text
            isTruncated = false
            return
        }
        
        // Text needs truncation
        isTruncated = true
        
        if showLastLines {
            // Show the last N lines (often contains conclusion/summary)
            let lastLines = lines.suffix(maxPreviewLines)
            
            // Just show the last lines without adding extra text
            displayText = "…\n" + lastLines.joined(separator: "\n")
        } else {
            // Show first N lines (traditional approach)
            let firstLines = lines.prefix(maxPreviewLines)
            displayText = firstLines.joined(separator: "\n") + "\n…"
        }
    }
    
    private func parseMarkdown(_ text: String) -> AttributedString {
        return MarkdownParser.parse(text)
    }
}

// MARK: - Full Text Overlay
struct FullTextOverlay: View {
    let content: [MessageContent]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.enumerated()), id: \.offset) { index, messageContent in
                        MessageContentView(content: messageContent)
                    }
                }
                .padding()
            }
            .navigationTitle("Full Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

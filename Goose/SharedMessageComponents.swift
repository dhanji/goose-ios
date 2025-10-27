import SwiftUI
import Markdown

// MARK: - Markdown Text View with Caching
struct MarkdownText: View {
    let text: String
    var isUserMessage: Bool = false
    @State private var cachedAttributedText: AttributedString?
    @State private var previousText = ""
    
    var body: some View {
        Group {
            if isUserMessage {
                Text(cachedAttributedText ?? AttributedString(text))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(cachedAttributedText ?? AttributedString(text))
                    .font(.system(size: 14, weight: .regular))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            if cachedAttributedText == nil {
                cachedAttributedText = MarkdownParser.parse(text)
                previousText = text
            }
        }
        .onChange(of: text) { _, newText in
            // Improved streaming: only reparse if text structure changed
            if !newText.hasPrefix(previousText) {
                // Text was modified (not appended) - full reparse needed
                withAnimation(.easeOut(duration: 0.15)) {
                    cachedAttributedText = MarkdownParser.parse(newText)
                }
            } else if newText != previousText {
                // Text was appended - efficient delta parsing
                let delta = String(newText.dropFirst(previousText.count))
                if let cached = cachedAttributedText {
                    // Simple append for streaming - only reparse if delta contains markdown syntax
                    if delta.contains("**") || delta.contains("*") || delta.contains("`") || 
                       delta.contains("[") || delta.contains("#") || delta.contains("\n\n") {
                        // Markdown syntax detected - reparse to maintain formatting
                        withAnimation(.easeOut(duration: 0.15)) {
                            cachedAttributedText = MarkdownParser.parse(newText)
                        }
                    } else {
                        // Plain text - just append efficiently with smooth transition
                        withAnimation(.easeOut(duration: 0.1)) {
                            cachedAttributedText = cached + AttributedString(delta)
                        }
                    }
                } else {
                    cachedAttributedText = MarkdownParser.parse(newText)
                }
            }
            previousText = newText
        }
        .animation(.easeOut(duration: 0.1), value: cachedAttributedText)
    }
}

// MARK: - Markdown Parser
struct MarkdownParser {
    static func parse(_ text: String) -> AttributedString {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = Document(parsing: trimmedText)
        
        var attributedString = AttributedString()
        for child in document.children {
            attributedString.append(processElement(child))
        }
        
        // Trim trailing newlines for cleaner output
        while attributedString.characters.last == "\n" {
            attributedString = AttributedString(attributedString.characters.dropLast())
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
            result.append(AttributedString("\n\n"))
            
        case let heading as Heading:
            var headingText = AttributedString()
            for child in heading.children {
                if let inlineChild = child as? InlineMarkup {
                    headingText.append(processInline(inlineChild))
                }
            }
            headingText.font = .system(size: max(18 - CGFloat(heading.level) * 2, 14), weight: .bold)
            result.append(headingText)
            result.append(AttributedString("\n\n"))
            
        case let codeBlock as CodeBlock:
            var codeText = AttributedString(codeBlock.code)
            codeText.font = .system(size: 14, design: .monospaced)
            codeText.backgroundColor = .secondary.opacity(0.1)
            result.append(codeText)
            result.append(AttributedString("\n\n"))
            
        case let list as UnorderedList:
            for child in list.children {
                result.append(processElement(child))
            }
            result.append(AttributedString("\n\n"))  // Paragraph break after list
            
        case let list as OrderedList:
            for child in list.children {
                result.append(processElement(child))
            }
            result.append(AttributedString("\n\n"))  // Paragraph break after list
            
        case let listItem as ListItem:
            result.append(AttributedString("• "))
            for child in listItem.children {
                var childResult = processElement(child)
                // Strip trailing newlines from list item content
                while childResult.characters.last == "\n" {
                    childResult = AttributedString(childResult.characters.dropLast())
                }
                result.append(childResult)
            }
            // Add a smaller line break for tighter spacing
            var smallBreak = AttributedString("\n")
            smallBreak.font = .system(size: 7)  // Half the normal 14pt font
            result.append(smallBreak)
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
            strongText.font = .system(size: 14, weight: .bold)
            return strongText
            
        case let emphasis as Emphasis:
            var emphasisText = AttributedString()
            for child in emphasis.children {
                if let inlineChild = child as? InlineMarkup {
                    emphasisText.append(processInline(inlineChild))
                }
            }
            emphasisText.font = .system(size: 14).italic()
            return emphasisText
            
        case let inlineCode as InlineCode:
            var codeText = AttributedString(inlineCode.code)
            codeText.font = .system(size: 14, design: .monospaced)
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

// MARK: - Full Text Overlay
struct FullTextOverlay: View {
    let content: [MessageContent]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.enumerated()), id: \.offset) { _, messageContent in
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

// MARK: - Tool Call Progress View

struct ToolCallProgressView: View {
    let toolCall: ToolCall
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with tool name and spinner
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                
                Text(toolCall.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            
            // Arguments snippet
            if !toolCall.arguments.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(getArgumentSnippets()), id: \.key) { item in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\(item.key):")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Text(item.value)
                                .font(.caption2)
                                .monospaced()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 24) // Align with text after spinner
            }
            
            // Status text
            Text("executing...")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.leading, 24)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
        )
        .frame(maxWidth: UIScreen.main.bounds.width * 0.7)
    }
    
    private func getArgumentSnippets() -> [(key: String, value: String)] {
        let maxArgs = 3 // Show up to 3 arguments
        let maxValueLength = 40 // Truncate values longer than this
        
        return toolCall.arguments
            .sorted { $0.key < $1.key }
            .prefix(maxArgs)
            .map { key, value in
                let valueString = String(describing: value.value)
                let truncated = valueString.count > maxValueLength 
                    ? String(valueString.prefix(maxValueLength)) + "..." 
                    : valueString
                return (key: key, value: truncated)
            }
    }
}


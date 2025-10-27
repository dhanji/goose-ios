# StackedToolCallsView Component Review

## Overview
The StackedToolCallsView system provides a sophisticated UI for displaying tool calls in the Goose iOS app. It handles both active (in-progress) and completed tool calls with three distinct visual states.

## Architecture

### Core Components

#### 1. **ToolCallState Enum** (`StackedToolCallsView.swift`)
```swift
enum ToolCallState: Identifiable {
    case active(id: String, timing: ToolCallWithTiming)
    case completed(id: String, completed: CompletedToolCall)
}
```
- Unified representation of tool calls regardless of completion status
- Provides consistent interface for accessing tool call data
- Used throughout the stacking system

#### 2. **StackedToolCallsView** (Main Container)
Handles three visual states:

**Single Tool Call:**
- Displays as a single `ToolCallCardView`
- No stacking or expansion behavior
- Clean, minimal presentation

**Stacked View (2+ tool calls, collapsed):**
- Shows up to 3 cards in a "Time Machine-style" stack
- Visual depth created with:
  - Offset: 12pt per card
  - Scale reduction: 0.02 per card
  - Progressive shadow reduction
- "+X more" indicator for 4+ tool calls
- Tap anywhere to expand

**Carousel View (expanded):**
- Full-width horizontal scrollable carousel
- Navigation controls (chevrons + counter)
- Scroll-based selection (card closest to center is selected)
- Selected card: scale 1.0, opacity 1.0
- Non-selected: scale 0.92, opacity 0.7
- Close button to collapse back to stack

#### 3. **ToolCallCardView** (Individual Card)
- Displays tool name with status indicator (spinner or checkmark)
- Shows up to 3 arguments (truncated to 40 chars)
- Tap behavior:
  - In stack: expands to carousel
  - In carousel (centered): long press opens detail view
  - In carousel (not centered): no action
- Fixed width: 70% of screen width

#### 4. **ToolCallDetailView** (Detail Sheet)
- Full-screen detail view for a single tool call
- Custom navigation bar with frosted glass effect
- Shows:
  - Tool name and status
  - All arguments (untruncated)
  - Tool call ID (selectable)
- Breadcrumb navigation: "Tool Call Details > [tool name]"

### Supporting Components

#### **ToolViews.swift**
Contains collapsible views for different tool content types:

1. **ToolRequestView** - Shows tool invocation with arguments (collapsible)
2. **ToolResponseView** - Shows tool results/errors
3. **ToolConfirmationView** - Permission requests (starts expanded)

#### **AssistantMessageView.swift**
- Filters out tool requests/responses from message content
- Shows completed tool calls as "pills" below message text
- Single task: direct navigation to output
- Multiple tasks: navigation to combined task view
- Pills show tool name + up to 2 arguments (30 char limit)

## Integration with ChatView

### Tool Call Tracking
```swift
@State private var activeToolCalls: [String: ToolCallWithTiming] = [:]
```

### Message Grouping
ChatView groups consecutive tool-only messages (messages with no text content):
- Groups displayed with single StackedToolCallsView
- Reduces visual clutter
- Better performance with many tool calls

### Rendering Logic
1. **Grouped messages**: Text content + StackedToolCallsView
2. **Regular messages**: Message content, then StackedToolCallsView if tool calls exist
3. **Tool-only groups**: Just StackedToolCallsView

## Visual Constants

### StackedToolCallsView
- `maxVisibleCards`: 3
- `cardOffsetIncrement`: 12pt
- `cardScaleDecrement`: 0.02
- `cardWidth`: 75% of screen width
- `cardSpacing`: 16pt (in carousel)

### ToolCallCardView
- Corner radius: 12pt
- Padding: 12pt
- Background: systemGray6
- Border: systemGray4, 0.5pt
- Max width: 70% of screen

### Argument Display
- **Card view**: 3 args max, 40 char truncation
- **Pill view**: 2 args max, 30 char truncation
- **Detail view**: All args, no truncation

## Strengths

1. **Progressive Disclosure**
   - Single card → Stack → Carousel → Detail
   - Each level reveals more information
   - User controls expansion

2. **Visual Hierarchy**
   - Clear depth perception in stack
   - Focused selection in carousel
   - Smooth animations between states

3. **Performance**
   - `.drawingGroup()` on stack for compositing
   - Message grouping reduces view count
   - Lazy rendering in carousel

4. **Consistency**
   - Unified ToolCallState abstraction
   - Consistent card appearance across states
   - Matched geometry transitions

## Areas for Improvement

### 1. **Card Width Inconsistency**
```swift
// StackedToolCallsView
private let cardWidth: CGFloat = UIScreen.main.bounds.width * 0.75

// ToolCallCardView
.frame(maxWidth: UIScreen.main.bounds.width * 0.7)
```
**Issue**: Different width calculations (75% vs 70%)
**Impact**: Cards may appear different sizes in different contexts
**Suggestion**: Use consistent width, preferably from a shared constant

### 2. **Argument Truncation Logic Duplication**
Similar truncation code appears in:
- `ToolCallCardView.getArgumentSnippets()` (3 args, 40 chars)
- `TaskPillContent.getArgumentSnippets()` (2 args, 30 chars)

**Suggestion**: Extract to shared utility function with configurable limits

### 3. **Navigation Pattern Complexity**
- ToolCallCardView uses hidden NavigationLink with @State
- Long press gesture vs tap gesture handling
- Different behavior based on context (stack vs carousel)

**Suggestion**: Consider using `.navigationDestination()` (iOS 16+) for cleaner code

### 4. **Hard-coded Screen Width**
```swift
UIScreen.main.bounds.width
```
**Issue**: Doesn't account for split-screen, iPad multitasking, or dynamic layouts
**Suggestion**: Use GeometryReader for container-relative sizing

### 5. **Carousel Selection Logic**
The scroll-based selection uses preference keys to find centered card:
```swift
.onPreferenceChange(CardPositionPreferenceKey.self) { positions in
    let screenCenter = geometry.size.width / 2
    // Find closest card...
}
```
**Issue**: Can be jittery during fast scrolling
**Suggestion**: Add debouncing or snap-to-center behavior

### 6. **Missing Empty State**
No explicit handling for empty tool calls array
**Suggestion**: Add guard or empty state view

### 7. **Accessibility**
- No VoiceOver labels for carousel navigation
- No accessibility hints for long press gesture
- Card counter not announced properly

**Suggestion**: Add `.accessibilityLabel()` and `.accessibilityHint()` modifiers

### 8. **Tool Confirmation TODO**
```swift
Button("Deny") {
    // TODO: Implement permission response
}
```
Permission buttons are not functional

## Recommendations

### High Priority
1. **Fix card width consistency** - Use shared constant
2. **Improve accessibility** - Add VoiceOver support
3. **Implement permission responses** - Complete TODO items

### Medium Priority
4. **Extract truncation logic** - Reduce code duplication
5. **Add container-relative sizing** - Replace UIScreen.main.bounds
6. **Improve carousel snap behavior** - Better UX during scrolling

### Low Priority
7. **Simplify navigation** - Consider modern SwiftUI patterns
8. **Add empty state handling** - Defensive programming
9. **Performance profiling** - Verify `.drawingGroup()` benefit

## Testing Considerations

### Test Cases Needed
1. Single tool call display
2. 2-3 tool calls (full stack visible)
3. 4+ tool calls (with "+X more" indicator)
4. Rapid tool call additions during execution
5. Tool call removal/completion during expansion
6. Rotation/size class changes
7. VoiceOver navigation
8. Memory usage with 20+ tool calls

### Edge Cases
- Tool calls with very long argument values
- Tool calls with no arguments
- Tool calls with special characters in names
- Rapid expand/collapse toggling
- Carousel at boundaries (first/last card)

## Code Quality

### Positive
- ✅ Well-structured with clear separation of concerns
- ✅ Good use of SwiftUI features (matchedGeometryEffect, preference keys)
- ✅ Comprehensive preview provider
- ✅ Clear documentation comments
- ✅ Consistent naming conventions

### Needs Attention
- ⚠️ Some magic numbers (could be extracted to constants)
- ⚠️ Long methods (carousel view could be split)
- ⚠️ TODOs in production code
- ⚠️ Limited error handling

## Summary

The StackedToolCallsView is a **well-designed, visually appealing component** that provides excellent progressive disclosure of tool call information. The three-state system (single → stack → carousel) works intuitively and the animations are smooth.

**Main concerns:**
1. Card width inconsistency
2. Accessibility gaps
3. Incomplete permission handling
4. Hard-coded screen dimensions

**Overall Grade: B+**
- Excellent concept and execution
- Minor polish needed for production readiness
- Accessibility improvements required
- Some technical debt to address

The component is production-ready for basic use but would benefit from the improvements listed above for a polished, accessible experience.

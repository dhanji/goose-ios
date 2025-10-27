# Right Edge Clipping - Targeted Fix

## Root Cause

The right edge clipping happens because:

1. **StackedToolCallsView** has `.frame(maxWidth: .infinity, alignment: .leading)`
2. **stackView** has `.padding(.trailing, 16)` 
3. **`.drawingGroup()`** clips content that extends beyond bounds
4. **Stacked cards** with offsets (up to 24pt for 3rd card) + shadows extend beyond the padded area

## Calculation

For 3 stacked cards:
- Card 0: offset 0pt
- Card 1: offset 12pt  
- Card 2: offset 24pt
- Shadow radius: up to 5pt
- Shadow x-offset: up to 4pt (for card 2)

**Total right-side extension**: 24pt (offset) + 5pt (shadow radius) + 4pt (shadow x) = ~33pt

But we only have **16pt trailing padding**, so we're clipping ~17pt on the right side!

## Solution Options

### Option 1: Increase Trailing Padding (Simplest)
```swift
private var stackView: some View {
    ZStack(alignment: .leading) {
        // ... existing code ...
    }
    .drawingGroup()
    .padding(.trailing, 40)  // Increased from 16 to 40
    .contentShape(Rectangle())
}
```

**Pros**: Minimal change, keeps performance optimization
**Cons**: Still has clipping risk, magic number

### Option 2: Remove .drawingGroup() (Recommended)
```swift
private var stackView: some View {
    ZStack(alignment: .leading) {
        // ... existing code ...
    }
    // REMOVED: .drawingGroup()
    .padding(.trailing, 16)
    .padding(.leading, 8)   // Add left padding for symmetry
    .contentShape(Rectangle())
}
```

**Pros**: No clipping, cleaner solution
**Cons**: Minor performance impact (likely negligible for 3 cards)

### Option 3: Add Padding Before .drawingGroup()
```swift
private var stackView: some View {
    ZStack(alignment: .leading) {
        // ... existing code ...
    }
    .padding(8)  // Padding INSIDE the drawing buffer
    .drawingGroup()
    .padding(.trailing, 16)
    .contentShape(Rectangle())
}
```

**Pros**: Keeps performance optimization, prevents clipping
**Cons**: Adds extra padding around content

### Option 4: Use .compositingGroup() Instead
```swift
private var stackView: some View {
    ZStack(alignment: .leading) {
        // ... existing code ...
    }
    .compositingGroup()  // Groups without clipping
    .padding(.trailing, 16)
    .contentShape(Rectangle())
}
```

**Pros**: Groups layers without clipping, good performance
**Cons**: Different rendering behavior than .drawingGroup()

## Recommended Fix

**Remove `.drawingGroup()`** - It's causing the clipping and the performance benefit for 3 cards is minimal.

```swift
private var stackView: some View {
    ZStack(alignment: .leading) {
        // Show only the top 3 cards
        ForEach(Array(toolCalls.prefix(maxVisibleCards).enumerated()), id: \.element.id) { index, call in
            ToolCallCardView(
                toolCallState: call,
                onTap: {
                    isExpanded = true
                }
            )
                .matchedGeometryEffect(id: call.id, in: cardAnimation)
                .offset(x: CGFloat(index) * cardOffsetIncrement)
                .scaleEffect(1.0 - CGFloat(index) * cardScaleDecrement)
                .shadow(
                    color: .black.opacity(0.05),
                    radius: 5 - CGFloat(index),
                    x: CGFloat(index) * 2,
                    y: 0
                )
                .zIndex(Double(maxVisibleCards - index))
        }
        
        // Show "+X more" indicator if there are more than 3 cards
        if toolCalls.count > maxVisibleCards {
            Text("+\(toolCalls.count - maxVisibleCards) more")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 2)
                )
                .offset(x: CGFloat(maxVisibleCards) * cardOffsetIncrement + 8)
        }
    }
    // REMOVED: .drawingGroup()
    .padding(.trailing, 16)
    .contentShape(Rectangle())
}
```

## If You Want to Keep .drawingGroup()

If performance is critical, increase the trailing padding:

```swift
.drawingGroup()
.padding(.trailing, 40)  // Increased to accommodate offsets + shadows
.contentShape(Rectangle())
```

## Testing

After fix, verify:
- [ ] Right edge of all cards fully visible
- [ ] Shadows on right side not clipped
- [ ] "+X more" indicator fully visible
- [ ] No performance degradation
- [ ] Works with 1, 2, 3, and 4+ cards

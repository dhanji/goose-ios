# Clipping and Shadow Issues Analysis

## Problems Identified

### 1. **`.drawingGroup()` Clips Shadows**
**Location**: Line 138 in `StackedToolCallsView.swift`

```swift
.drawingGroup() // Composite stacked cards as single layer for better performance
.padding(.trailing, 16)
```

**Issue**: `.drawingGroup()` renders the view into an offscreen buffer, which clips content that extends beyond the view bounds. This includes:
- Drop shadows on the cards
- Any overflow from the stacked cards

**Impact**: 
- Shadows on stacked cards are cut off
- The visual depth effect is diminished
- Cards may appear to be clipped at edges

### 2. **Insufficient Padding for Shadows**
**Location**: Multiple places

The shadows are applied but there's no padding to accommodate them:

```swift
// In stackView
.shadow(
    color: .black.opacity(0.05),
    radius: 5 - CGFloat(index),
    x: CGFloat(index) * 2,
    y: 0
)
```

With a shadow radius of up to 5pt and x-offset of up to 4pt (for index 2), we need at least 5-6pt of padding on all sides to prevent clipping.

### 3. **Frame Constraints Too Tight**
**Location**: Line 350 in `ToolCallCardView`

```swift
.frame(maxWidth: UIScreen.main.bounds.width * 0.7)
```

Combined with the background and overlay modifiers, this creates a tight bounding box that clips shadows.

### 4. **VStack Alignment Issues**
**Location**: Line 66

```swift
VStack(alignment: .leading, spacing: 8) {
```

The VStack with `.leading` alignment combined with `.frame(maxWidth: .infinity, alignment: .leading)` can cause content to be pushed to the edge, leaving no room for shadows on the left.

## Solutions

### Fix 1: Remove or Conditionally Use `.drawingGroup()`

**Option A - Remove it** (Simplest):
```swift
// Remove .drawingGroup() entirely
.padding(.trailing, 16)
.padding(.leading, 8)  // Add left padding for shadows
.padding(.vertical, 8)  // Add vertical padding for shadows
.contentShape(Rectangle())
```

**Option B - Add padding before drawingGroup**:
```swift
.padding(8)  // Padding INSIDE the drawing group
.drawingGroup()
.padding(.trailing, 16)
```

**Option C - Use compositingGroup instead**:
```swift
.compositingGroup()  // Groups without clipping
.shadow(color: .black.opacity(0.05), radius: 5)  // Apply shadow to group
.padding(.trailing, 16)
```

### Fix 2: Add Shadow Padding to Cards

In `ToolCallCardView`, add padding around the background:

```swift
.padding(12)
.background(
    RoundedRectangle(cornerRadius: 12)
        .fill(Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)  // Add shadow here
)
.padding(6)  // Padding to accommodate shadow
.frame(maxWidth: UIScreen.main.bounds.width * 0.7)
```

### Fix 3: Adjust Container Padding

In the main `body`:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        // ... content ...
    }
    .padding(.bottom, 8)
    .padding(.top, 8)
    .padding(.horizontal, 8)  // Add horizontal padding
    .frame(maxWidth: .infinity, alignment: .leading)
}
```

### Fix 4: Use GeometryReader for Better Bounds

Replace hard-coded screen width with container-relative sizing:

```swift
GeometryReader { geometry in
    VStack(alignment: .leading, spacing: 8) {
        // ... content ...
    }
    .frame(maxWidth: geometry.size.width * 0.75)
}
```

## Recommended Complete Fix

Here's the comprehensive fix for the stackView:

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
    .padding(.horizontal, 8)  // Add horizontal padding for shadows
    .padding(.vertical, 6)     // Add vertical padding for shadows
    .padding(.trailing, 16)
    .contentShape(Rectangle())
}
```

## Testing Checklist

After applying fixes, verify:
- [ ] Shadows visible on all stacked cards
- [ ] No clipping on left edge of first card
- [ ] No clipping on right edge of last card
- [ ] No clipping on top/bottom of cards
- [ ] "+X more" indicator fully visible with shadow
- [ ] Smooth animation when expanding/collapsing
- [ ] Performance still acceptable (test with 10+ cards)
- [ ] Works in light and dark mode
- [ ] Works on different screen sizes (iPhone SE to Pro Max)

## Performance Consideration

Removing `.drawingGroup()` may have a minor performance impact with many cards. Monitor for:
- Frame drops during animation
- Lag when adding new cards
- Memory usage with 20+ cards

If performance degrades, consider:
1. Using `.compositingGroup()` instead
2. Applying `.drawingGroup()` only when not animating
3. Limiting the number of visible stacked cards to 2 instead of 3

## Alternative: Shadow on Container

Instead of shadows on individual cards, apply one shadow to the entire stack:

```swift
private var stackView: some View {
    ZStack(alignment: .leading) {
        // ... cards without individual shadows ...
    }
    .background(
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.clear)
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    )
    .padding(10)  // Padding for shadow
    .padding(.trailing, 16)
}
```

This approach:
- ✅ Simpler shadow management
- ✅ Better performance
- ❌ Less depth perception between cards
- ❌ Different visual effect

# Fix: Right Edge Clipping in StackedToolCallsView

## Issue
The right edge of stacked tool call cards was being clipped, cutting off shadows and card content.

## Root Cause
The `.drawingGroup()` modifier was rendering the view into an offscreen buffer with insufficient padding:
- Stacked cards extend 24pt to the right (3rd card offset)
- Shadows extend an additional ~9pt (5pt radius + 4pt x-offset)
- Total extension needed: ~33pt
- Available trailing padding: Only 16pt
- **Result**: ~17pt of clipping on the right edge

## Solution
Removed `.drawingGroup()` modifier from the `stackView` in `StackedToolCallsView.swift`

### Before
```swift
}
.drawingGroup() // Composite stacked cards as single layer for better performance
.padding(.trailing, 16)
.contentShape(Rectangle())
```

### After
```swift
}
.padding(.trailing, 16)
.contentShape(Rectangle())
```

## Impact
- ✅ Right edge shadows now fully visible
- ✅ Cards no longer clipped
- ✅ "+X more" indicator fully visible
- ⚠️ Minor performance impact (negligible for 3 cards)

## Performance Notes
The `.drawingGroup()` modifier was originally added for performance optimization by compositing the stacked cards as a single layer. However:
- Only 3 cards are shown in the stack (maxVisibleCards = 3)
- Modern iOS devices handle 3 layered views easily
- The clipping issue outweighs the minimal performance benefit

If performance becomes an issue with many cards, alternatives include:
1. Use `.compositingGroup()` instead (groups without clipping)
2. Add padding before `.drawingGroup()` to accommodate shadows
3. Increase trailing padding to 40pt

## Testing Needed
- [ ] Verify right edge fully visible with 2 cards
- [ ] Verify right edge fully visible with 3 cards  
- [ ] Verify right edge fully visible with 4+ cards ("+X more" indicator)
- [ ] Check shadows are visible on all cards
- [ ] Test expand/collapse animation still smooth
- [ ] Test on different screen sizes (SE to Pro Max)
- [ ] Verify no performance degradation during normal use

## Files Changed
- `Goose/StackedToolCallsView.swift` - Removed `.drawingGroup()` on line 138

## Branch
`spence/polishchat`

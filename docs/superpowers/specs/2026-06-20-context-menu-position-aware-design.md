# Context Menu Position-Aware Design

## Goal
Make the file-explorer context menu aware of the window edges so that when the user right-clicks near the bottom (or right edge) of the window, the menu flips to stay fully visible instead of running off-screen.

## Background
The current `ContextMenu.showAt(x, y)` in `src/ui/context_menu.nim` places the menu’s top-left corner exactly at the click coordinates. On the file explorer, this means a right-click near the bottom of the window causes the menu to extend past the window boundary and become unreadable/unreachable.

## Design

### Behavior
- When the menu would extend below the window bottom, flip it vertically: the menu’s **bottom edge aligns with the click Y**, growing upward.
- When the menu would extend past the window right edge, flip it horizontally: the menu’s **right edge aligns with the click X**, growing leftward.
- Flipping is applied independently for each axis.
- When there is enough space, the menu keeps its current top-left-at-cursor behavior.

### API Change
Add a new overload to `ContextMenu`:

```nim
proc showAt*(menu: ContextMenu, x, y, screenW, screenH: int)
```

The existing `showAt*(menu: ContextMenu, x, y: int)` remains unchanged so that existing callers (submenus, branch menu, LSP menu, etc.) are not affected.

The new overload:
1. Computes menu width and height exactly like the current `showAt`.
2. Computes candidate position `(x, y)`.
3. If `x + width > screenW`, sets `x = x - width`.
4. If `y + height > screenH`, sets `y = y - height`.
5. Assigns `menu.bounds` with the adjusted position.

### Call-Site Update
In `src/app/app.nim`, change the explorer context-menu trigger from:

```nim
app.contextMenu.showAt(e.x, e.y)
```

to:

```nim
app.contextMenu.showAt(e.x, e.y, app.width, app.height)
```

`app.width` and `app.height` are already available in the input/render scope.

### Scope
- Only the explorer context menu is updated to use the new overload.
- Submenus and other context menus continue to use the simple `showAt(x, y)`.
- No visual or interaction changes when the menu already fits on screen.

## Testing
- Manual verification: right-click a file/folder near the bottom of the window and confirm the menu grows upward.
- Manual verification: right-click near the right edge of the window and confirm the menu grows leftward.
- Regression check: right-click in the middle of the window and confirm the menu still opens top-left at the cursor.

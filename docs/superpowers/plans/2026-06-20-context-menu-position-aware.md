# Context Menu Position-Aware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the file-explorer context menu flip vertically/horizontally when opened near window edges so it stays fully visible.

**Architecture:** Add a pure `fitMenuBounds` helper and a new `showAt` overload that accepts screen dimensions in `src/ui/context_menu.nim`. The explorer call site in `src/app/app.nim` passes the full window size. Existing callers keep using the original `showAt(x, y)`.

**Tech Stack:** Nim, uirelays, project test runner (`nim c -r tests/test_context_menu.nim`)

---

## File Structure

- `src/ui/context_menu.nim` — add `fitMenuBounds` helper and `showAt(menu, x, y, screenW, screenH)` overload.
- `src/app/app.nim` — update the explorer right-click trigger to pass `app.width` and `app.height`.
- `tests/test_context_menu.nim` — unit tests for `fitMenuBounds` covering no-flip, bottom-flip, right-flip, and clamping cases.

---

## Task 1: Add position-aware `showAt` overload

**Files:**
- Modify: `src/ui/context_menu.nim:126-144`
- Create: `tests/test_context_menu.nim`

- [ ] **Step 1: Write the failing test**

Create `tests/test_context_menu.nim`:

```nim
import ../src/ui/context_menu

proc check(desc: string, r: Rect, expected: Rect) =
  if r.x == expected.x and r.y == expected.y and r.w == expected.w and r.h == expected.h:
    echo "PASS: ", desc
  else:
    echo "FAIL: ", desc, " got ", r, " expected ", expected
    quit(1)

# No flip needed
check("fits inside", fitMenuBounds(100, 100, 50, 50, 200, 200), rect(100, 100, 50, 50))

# Bottom flip: menu bottom should align with click Y
check("flips up near bottom", fitMenuBounds(100, 180, 50, 50, 200, 200), rect(100, 130, 50, 50))

# Right flip: menu right should align with click X
check("flips left near right", fitMenuBounds(180, 100, 50, 50, 200, 200), rect(130, 100, 50, 50))

# Both axes flip
check("flips both axes", fitMenuBounds(180, 180, 50, 50, 200, 200), rect(130, 130, 50, 50))

# Clamping when menu is larger than screen
check("clamps to top-left", fitMenuBounds(10, 10, 80, 80, 60, 60), rect(0, 0, 80, 80))
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
nim c -r tests/test_context_menu.nim
```

Expected: compile fails because `fitMenuBounds` is not defined.

- [ ] **Step 3: Implement `fitMenuBounds` and the new `showAt` overload**

In `src/ui/context_menu.nim`, insert the helper before the existing `showAt` proc and add the overload after it.

Add before `proc showAt*(menu: ContextMenu, x, y: int)` (~line 126):

```nim
proc fitMenuBounds*(x, y, w, h, screenW, screenH: int): Rect =
  var nx = x
  var ny = y
  if nx + w > screenW:
    nx = x - w
  if ny + h > screenH:
    ny = y - h
  if nx < 0:
    nx = 0
  if ny < 0:
    ny = 0
  rect(nx, ny, w, h)
```

Add after the existing `showAt` proc (~line 144):

```nim
proc showAt*(menu: ContextMenu, x, y, screenW, screenH: int) =
  menu.showAt(x, y)
  menu.bounds = fitMenuBounds(menu.bounds.x, menu.bounds.y,
                              menu.bounds.w, menu.bounds.h,
                              screenW, screenH)
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
nim c -r tests/test_context_menu.nim
```

Expected:

```
PASS: fits inside
PASS: flips up near bottom
PASS: flips left near right
PASS: flips both axes
PASS: clamps to top-left
```

- [ ] **Step 5: Commit**

```bash
git add src/ui/context_menu.nim tests/test_context_menu.nim
git commit -m "feat: add position-aware context menu showAt overload"
```

---

## Task 2: Wire the explorer context menu to use the new overload

**Files:**
- Modify: `src/app/app.nim:1925-1926`

- [ ] **Step 1: Update the explorer call site**

Change:

```nim
buildExplorerContextMenu(app.contextMenu, node, app.fileExplorer.rootPath, app.width, app.height, app.uiFont, callbacks)
app.contextMenu.showAt(e.x, e.y)
```

To:

```nim
buildExplorerContextMenu(app.contextMenu, node, app.fileExplorer.rootPath, app.width, app.height, app.uiFont, callbacks)
app.contextMenu.showAt(e.x, e.y, app.width, app.height)
```

- [ ] **Step 2: Build the project to verify no compile errors**

Run:

```bash
nimble build
```

Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/app/app.nim
git commit -m "feat: use position-aware showAt for explorer context menu"
```

---

## Self-Review

**Spec coverage:**
- Bottom-flip behavior: covered by Task 1 `fitMenuBounds` implementation and `flips up near bottom` test.
- Right-flip behavior: covered by Task 1 `flips left near right` test.
- Explorer call site update: covered by Task 2.
- Backward compatibility: original `showAt(x, y)` is untouched; other callers continue to work.

**Placeholder scan:**
- No TBD/TODO/fill-in-later steps.
- All code blocks contain complete Nim code.
- All commands include expected output.

**Type consistency:**
- `fitMenuBounds` returns `Rect` from `uirelays/screen`, matching existing `menu.bounds` type.
- New `showAt` overload signature uses `int` for all parameters, consistent with existing `showAt(x, y: int)`.

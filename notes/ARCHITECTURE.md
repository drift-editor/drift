# Drift Editor — Architecture Overview

Drift is a lightweight IDE/text editor written in Nim, built on the **uirelays** GUI framework. It is a single-window, immediate-mode UI.

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Nim 2.2 |
| GUI Framework | uirelays |
| Concurrency | std/atomics + custom SPSC channels |
| Async I/O | chronos (for LSP/DAP network I/O) |
| Image Loading | pixie |
| Font Rendering | uirelays (embedded TTF: FiraCode, CascadiaMono, Roboto) |

## Directory Structure

```
src/
├── drift.nim                    # Entry point: CLI args → createApp → run loop
├── app/
│   ├── app.nim                  # Main App god object, event loop, render loop
│   ├── app_layout.nim           # Window layout bounds (sidebar, editor, terminal, etc.)
│   ├── app_tree.nim             # Node-tree hit testing for componentized UI
│   ├── app_commands.nim         # Command registry (file.close, edit.undo, etc.)
│   ├── commands.nim             # Command types and categories
│   ├── event_router.nim         # Keyboard/mouse event routing/dispatch
│   ├── app_cursors.nim          # Cursor shape management
│   └── explorer_context.nim     # File explorer right-click context actions
├── core/
│   ├── types.nim                # Domain types (CursorPos, Selection, Rect, Color, etc.)
│   ├── document.nim             # Pure text document model (lines, undo/redo)
│   ├── history.nim              # Undo/redo history stack
│   ├── selection.nim            # Selection and multi-cursor logic
│   ├── errors.nim               # Result[T, E] error handling
│   ├── config.nim               # TOML config loading
│   ├── recent_files.nim         # Recent files persistence
│   └── security_scoped_bookmarks.nim  # macOS sandbox bookmarks
├── editor/
│   ├── state.nim                # EditorState: cursor, scroll, viewport
│   ├── color_highlight.nim      # Syntax highlighting engine
│   ├── nim_highlighter.nim      # Nim-specific lexer
│   ├── color_parser.nim         # Hex/css color preview in gutter
│   ├── diff_engine.nim          # Myers DP diff + prefix/suffix fallback
│   ├── git_diff.nim             # Git diff marker computation
│   ├── marker_manager.nim       # Breakpoint/diagnostic line markers
│   └── sticky_scroll.nim        # Sticky parent-scope header lines
├── services/
│   ├── lsp_thread.nim           # LSP client worker thread (JSON-RPC over TCP)
│   ├── lsp_client.nim           # LSP protocol message builder/parser
│   ├── ai_thread.nim            # AI assistant worker thread (ACP/JSON-RPC over stdio)
│   ├── dap_thread.nim           # Debug Adapter Protocol worker thread
│   ├── dap_client.nim           # DAP protocol message builder/parser
│   └── git.nim                  # Git command wrapper (execGitCommand)
├── ui/
│   ├── diff_view.nim            # Side-by-side diff viewer (dual SynEdit)
│   ├── tabs.nim                 # Tab bar component
│   ├── file_explorer.nim        # Sidebar file tree
│   ├── git_panel.nim            # Git status / changed files panel
│   ├── search_panel.nim         # Find/replace + workspace search
│   ├── command_palette.nim      # Quick command picker
│   ├── ai_panel.nim             # AI chat panel
│   ├── debug_panel.nim          # Debug variables/scopes panel
│   ├── debug_sidebar.nim        # Debug controls (Run/Stop) + call stack
│   ├── diagnostics_panel.nim    # LSP diagnostics/problems panel
│   ├── theme.nim                # Theme colors and tokens
│   ├── theme_loader.nim         # Theme JSON loading
│   ├── theme_selector.nim       # Theme switcher UI
│   ├── notification.nim         # Toast notifications
│   ├── dialog.nim               # Input/confirm dialogs
│   ├── context_menu.nim         # Right-click menus
│   ├── file_dialog.nim          # Open/save file dialogs
│   ├── statusbar.nim            # Bottom status bar
│   ├── hover_tooltip.nim        # LSP hover tooltip
│   ├── location_picker.nim      # Go-to-definition location picker
│   ├── welcome_screen.nim       # Startup welcome screen
│   ├── icons.nim                # Icon atlas / icon IDs
│   └── node.nim                 # Component tree node base type
├── widgets/
│   ├── synedit.nim              # (from uirelays) Syntax-highlighting text editor
│   └── widgets.nim              # Reusable UI primitives (InputBox, etc.)
└── utils/
    ├── file_watcher.nim         # Directory change monitoring
    └── text.nim                 # Text utility helpers
```

## Concurrency Model

Drift is single-threaded for the UI, with **three background worker threads**:

```
┌─────────────────────────────────────────────────────────────┐
│                      Main Thread (UI)                        │
│  Event loop → render → dispatch commands                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │ LSP Chan│  │ AI Chan │  │ DAP Chan│  ← SPSC channels     │
│  └────┬────┘  └────┬────┘  └────┬────┘                      │
└───────┼────────────┼────────────┼────────────────────────────┘
        │            │            │
   ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
   │LSPThread│  │AIThread │  │DAPThread│
   │chronos  │  │stdio    │  │chronos  │
   │TCP      │  │ACP      │  │TCP      │
   └─────────┘  └─────────┘  └─────────┘
```

- **LSPThread**: Owns TCP connection to language server. Sends hover/definition/didOpen/didChange requests. Receives diagnostics/hover/location responses.
- **AIThread**: Spawns `kimi-cli` process, communicates via JSON-RPC over stdio (Agent Communication Protocol). Streams response chunks back to UI.
- **DAPThread**: Owns TCP connection to debug adapter. Manages breakpoints, stack traces, variables, continue/step.

All threads communicate with the main thread via `SPSChannel[T]` — a lock-free single-producer/single-consumer ring buffer built on `std/atomics`.

## App Lifecycle

```
drift.nim main()
  └── createApp(config)          # Allocates App, loads fonts, creates widgets
      └── init()                 # Initializes LSP, file watcher, welcome screen
          └── run()              # Main event/render loop
              ├── pollEvents()   # uirelays event polling
              ├── processInput() # Keyboard/mouse → commands → state changes
              ├── syncThreads()  # Drain LSP/AI/DAP channel messages
              └── render()       # Draw frame
          └── cleanup()          # Shutdown threads, save state
```

## The `App` God Object

`app.nim` contains a single `App` ref object that holds **all** application state:

- **Window**: width, height, focus string
- **Fonts**: 5 font slots (editor, UI, terminal, status, tooltip) + metrics
- **Buffers**: `seq[Buffer]` with tab bar index. Each Buffer wraps a `SynEdit`
- **Panels**: sidebar, git, search, debug, terminal, AI, diagnostics
- **Threads**: LSP, AI, DAP thread handles + message channels
- **Overlays**: command palette, theme selector, dialogs, tooltips
- **Diff View**: shared `DiffView` instance (dual SynEdit panes)
- **Componentization**: `rootNode` tree for hit-testing, `commands` registry, `gi` global input

This is not a clean layered architecture — it's a pragmatic monolith where the main loop directly calls into panel `render()` and `handleInput()` methods.

## Rendering Pipeline (Per Frame)

```
render(frame)
  ├── computeLayout()              # sidebarW, editorBounds, termBounds, etc.
  ├── buildNodeTree()              # componentized hit-test tree
  ├── drawSidebar()                # file explorer OR git OR search OR debug
  ├── drawRightPanel()             # AI panel (if visible)
  ├── drawEditor()
  │   ├── if diff buffer: diffView.render()
  │   ├── if image buffer: drawImage()
  │   └── else: synedit.draw()     # text editor
  ├── drawTerminal()               # bottom terminal panel
  ├── drawStatusBar()              # git branch, cursor pos, LSP status
  ├── drawOverlays()               # command palette, notifications, dialogs
  └── drawTooltips()               # LSP hover tooltip
```

All rendering is **immediate mode** via uirelays. There is no retained scene graph (except the optional `rootNode` for hit testing).

## Key Components

### SynEdit (uirelays)
The text editor widget. Features:
- Incremental syntax highlighting (token-based, with highlight stack)
- Line numbers, gutter, scrollbar
- Multi-cursor (via `selection.nim`)
- Full-width line background decorations (used by diff view)
- Sticky scroll (parent scope headers float at top)
- Search result / diagnostic / diff minimap markers

### Diff View
- Tab-based: opens as a normal buffer with `diffPath` set
- Shared `DiffView` object with dual `SynEdit` panes
- `diff_engine.nim`: Myers DP LCS for small files, prefix/suffix extraction for large files
- Theme-aware background colors (delete=red, insert=green, replace=yellow)

### LSP Integration
- `lsp_thread.nim`: Background thread running chronos async loop
- `lsp_client.nim`: Raw JSON-RPC message framing
- Features: hover, go-to-definition, diagnostics, didOpen/didChange
- Supports nimlangserver and nimsuggest

### Debug (DAP)
- `dap_thread.nim` + `dap_client.nim`: DAP over TCP
- `debug_sidebar.nim`: Run/Stop buttons, call stack, breakpoints
- `debug_panel.nim`: Variables/scopes inspection

### AI Panel
- `ai_thread.nim`: Spawns `kimi-cli`, ACP protocol
- Streaming response chunks into chat UI
- File-change notifications from AI agent

## License

Dual-licensed under **AGPL-3.0** (open source) and **Commercial License** (proprietary use).
See `LICENSE` and `LICENSE-AGPL` in the repository root.

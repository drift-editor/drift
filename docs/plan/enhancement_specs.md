# Drift Editor Enhancement Specs

> Objective: incrementally improve Drift's feature set and fit-and-finish without redesigning the UI or changing the immediate-mode architecture.
> Scope: the existing single-window, panel-based layout is preserved; improvements are additive and configurable.

---

## 1. Current Snapshot

Drift is a Nim 2.2 GUI editor built on `uirelays` with:

- Core editing via `SynEdit` (multi-cursor, line ops, undo/redo, sticky scroll)
- Syntax highlighting for Nim, C/C++, JS/TS, Python, Rust, Java, C#, XML/HTML, Markdown
- File explorer + git status + side-by-side diff viewer
- LSP: hover, go-to-definition, diagnostics, didOpen/didChange
- DAP debugger (breakpoints, call stack, variables)
- AI panel (ACP agents + built-in OpenAI-compatible client)
- Terminal panel, command palette, notifications, theme system
- TOML keybindings + JSON config

Notable gaps when compared with modern lightweight editors (Zed, Helix, VS Code, Micro, Moe):

- LSP completion, signature help, formatting, rename, references, document/workspace symbols, code actions, folding ranges
- LSP is currently hard-coded to Nim (auto-start only on `.nim` files; hover/definition only for Nim buffers)
- No bracket/quote match highlighting or jump-to-matching-bracket
- No auto-save or persistent unsaved-change recovery
- Search has regex/case/word toggles but lacks persistence, result counters, and global result navigation polish
- Recent files list is plain filenames without paths, pin, clear, or tooltip
- Welcome screen "Documentation" action is a no-op
- Status bar line-ending/encoding sections are declared but often empty
- Config is JSON-only; only theme selector and a few command-palette toggles exist as UI
- File watcher auto-reloads unmodified buffers, but does not prompt when the buffer has local edits
- Command palette cannot execute commands that need arguments
- Debug variables/scopes panel receives DAP responses but does not display them (stub)
- Workspace search runs synchronously and blocks the UI thread
- Terminal implementation is a single widget; `docs/TERMINAL_DOCUMENTATION.md` describes a non-existent subsystem
- Sidebar has an `Extensions` enum value but no extension system

---

## 2. Design Principles

1. **Keep the UI as-is** — same panels, same layout, same widget shapes. Add new widgets only where a feature truly needs one and a natural place already exists (e.g., a completion popup over the editor, a signature-help tooltip).
2. **Add, don't replace** — new commands, LSP methods, config keys, and status-bar indicators should layer on top of existing code.
3. **Configurable by default** — every behavior change gets a `config.json` toggle so users can disable it.
4. **Nim-first, multi-language** — prioritize Nim LSP (`nimlangserver` / `minlsp`) workflows, but implement LSP methods generically so other servers benefit.
5. **Test in place** — add/update unit tests for `editor/`, `services/`, and `core/` modules that are touched.

---

## 3. Detail Improvements (Low Risk, High Polish)

### 3.1 Editor Micro-Interactions

| # | Feature | What it does | Config key | Notes |
|---|---------|--------------|------------|-------|
| D1 | Bracket/quote match highlight | Briefly highlight the matching `()[]{}` or quote pair when cursor is adjacent; optional persistent underline. | `bracketHighlight` (exists) | **TODO / deferred**: requires uirelays SynEdit bracket-match API improvements. See [drift-editor/drift#24](https://github.com/drift-editor/drift/issues/24). |
| D2 | Jump to matching bracket | Command `navigate.matchingBracket` bound to `Ctrl+Shift+\` moves cursor to the paired bracket. | — | **TODO / deferred**: depends on D1 / uirelays issue [drift-editor/drift#25](https://github.com/drift-editor/drift/issues/25). |
| D3 | Smart auto-indent | After `Enter`, copy leading whitespace; for Nim/Python, add one indent level after `:`, `{`, `(`, `[` at EOL; outdent on `return`, `break`, `continue`, `raise`. | `autoIndent` (exists) | **TODO / deferred**: requires uirelays SynEdit indent hooks. See [drift-editor/drift#26](https://github.com/drift-editor/drift/issues/26). |
| D4 | Auto-save | Save modified buffers after a configurable idle delay; only for files with a path. | `autoSave: "off" | "afterDelay"`, `autoSaveDelayMs` | Add timer in main loop; show dot indicator in tab when dirty. |
| D5 | Auto-reload changed files | When `file_watcher` detects an external change and buffer is unmodified, reload silently; if modified, show a non-blocking toast with "Reload" / "Keep". | `fileWatcherAutoReload` | Reuse existing file watcher. |
| D6 | Duplicate selection | `edit.duplicateSelection` (`Ctrl+D` when selection active) duplicates selected text; without selection duplicates line. | — | Extend existing `duplicateLine` logic. |
| D7 | Cycle clipboard ring | `edit.cycleClipboard` (`Ctrl+Shift+V`) cycles last N clipboard entries. | `clipboardHistorySize` | Keep simple in-memory ring. |

### 3.2 Tabs & Buffers

| # | Feature | What it does |
|---|---------|--------------|
| D8 | Unsaved-change indicator | Show `•` in tab label and title bar when buffer dirty. |
| D9 | Tab close on middle-click | Middle mouse button closes a tab. **TODO / deferred**: needs reliable middle-mouse event delivery from uirelays. See [drift-editor/drift#27](https://github.com/drift-editor/drift/issues/27). |
| D10 | Recent-file path tooltip | Hover over Recent item on Welcome screen shows full path tooltip. |
| D11 | Pinned recent files | Right-click Recent item → "Pin" keeps it at top; stored in config `pinnedRecentFiles`. |
| D12 | Reopen closed tab | `Ctrl+Shift+T` reopens the last closed buffer from a small history. |

### 3.3 Search (polish existing toggles)

Search already supports regex, case-sensitive, and whole-word toggles. These items refine the experience without changing UI shape.

| # | Feature | What it does | Config/Notes |
|---|---------|--------------|--------------|
| D13 | Persist search options | Remember regex/case/word toggles and query per session; optionally persist in config. | `search.rememberOptions` |
| D14 | Find result counter | "3 / 12" indicator in search panel. | |
| D15 | Search history | `Up`/`Down` in search box cycles previous queries; persists `searchHistory` list. | |
| D16 | Workspace search async | Move `findAll` workspace search off the UI thread so the editor stays responsive. | Use LSP `workspace/symbol` when possible; otherwise background thread/process. |
| D17 | Global find results panel | Bottom panel tab showing workspace results with file/path/context; click jumps to location. | Reuse bottom-panel tabs. |

### 3.4 Status Bar & Tooltips

| # | Feature | What it does |
|---|---------|--------------|
| D18 | Line ending display | Show `CRLF`/`LF` in status bar; clicking opens picker (reuse `context_menu`). |
| D19 | Encoding display | Show `UTF-8` in status bar; future picker placeholder. |
| D20 | LSP status hover | Hover status bar LSP icon shows server name + ready/error message. |
| D21 | Hover tooltip markdown | Render LSP hover contents as simple markdown (bold, code blocks, links). | Use existing `md_segments.nim`. |

### 3.5 Command Palette

| # | Feature | What it does |
|---|---------|--------------|
| D22 | Argument-aware commands | Allow commands like `>Go to Line: 42` or `>Open File: foo.nim` from palette. |
| D23 | Recently used commands | Sort recently executed commands higher. |

---

## 4. Functional Improvements (Medium Scope)

### 4.1 LSP Expansion

All new LSP methods are added to `services/lsp_client.nim` and exposed through `services/lsp_thread.nim` message kinds. UI entry points use existing overlays where possible.

| # | Feature | LSP method | UI entry point | Notes |
|---|---------|------------|----------------|-------|
| F1 | **Completion** | `textDocument/completion` | Trigger on `Ctrl+Space` and optionally on typing identifiers; popup list above/below cursor. | **TODO / deferred**: needs a completion popup widget. See [drift-editor/drift#13](https://github.com/drift-editor/drift/issues/13). |
| F2 | **Signature help** | `textDocument/signatureHelp` | Show tooltip while typing inside function call `(|)`. | **TODO / deferred**: needs signature-help tooltip/popup support. See [drift-editor/drift#14](https://github.com/drift-editor/drift/issues/14). |
| F3 | **Format document** | `textDocument/formatting` | Command `edit.formatDocument` (`Shift+Alt+F`). | Apply `TextEdit[]` via `document.nim` helpers. |
| F4 | **Format selection** | `textDocument/rangeFormatting` | Command `edit.formatSelection` when selection active. | |
| F5 | **Rename symbol** | `textDocument/rename` | Command `editor.renameSymbol` (`F2`) with input dialog; apply workspace edit. | |
| F6 | **Find references** | `textDocument/references` | Command `editor.findReferences` (`Shift+F12`); results in bottom panel or location picker. | Reuse `location_picker.nim`. |
| F7 | **Document symbols** | `textDocument/documentSymbol` | Command `workbench.gotoSymbol` (`Ctrl+Shift+O`); fuzzy picker. | Reuse command palette list mode. |
| F8 | **Workspace symbols** | `workspace/symbol` | Command `workbench.gotoSymbolInWorkspace` (`Ctrl+T`). | |
| F9 | **Code actions** | `textDocument/codeAction` | Lightbulb in gutter on diagnostics; command `editor.quickFix`. | **TODO / deferred**: needs gutter/inline hint API. See [drift-editor/drift#15](https://github.com/drift-editor/drift/issues/15). |
| F10 | **Folding ranges** | `textDocument/foldingRange` | `Ctrl+Shift+[` / `Ctrl+Shift+]` toggle fold at cursor. | **TODO / deferred**: needs SynEdit folding primitives. See [drift-editor/drift#16](https://github.com/drift-editor/drift/issues/16). |
| F11 | **Selection ranges** | `textDocument/selectionRange` | `Shift+Alt+Right` expands selection by syntax; `Shift+Alt+Left` contracts. | **TODO / deferred**: needs SynEdit selection-range API. See [drift-editor/drift#17](https://github.com/drift-editor/drift/issues/17). |
| F12 | **Document highlight** | `textDocument/documentHighlight` | Highlight other occurrences of symbol under cursor; optional. | **TODO / deferred**: needs document-highlight marker API. See [drift-editor/drift#18](https://github.com/drift-editor/drift/issues/18). |

**LSP client details**
- Advertise capabilities already declared in `initialize` (they are present, just unused).
- Add document-version tracking for `TextEdit` application.
- Cancel in-flight requests on cursor move for completion/hover.
- Expose `serverCapabilities` so UI can disable unavailable features per server.
- Remove Nim-only assumptions in `app.nim` so LSP starts for any language with a configured server command; map language id to server via `lspServer` or a per-language table in config.

### 4.2 Debug (close stub gaps)

| # | Feature | What it does |
|---|---------|--------------|
| F13 | Variables/scopes display | Wire `dmkVariablesResponse` into `debug_panel.nim`; show scopes and variables with expandable tree. | High value, small UI change. |
| F14 | Evaluate expression | DAP `evaluate` request bound to a bottom-panel input; show result in debug output. |
| F15 | Set variable value | Double-click a variable value in debug panel to edit and send DAP `setVariable`. |

### 4.3 Config & Settings

| # | Feature | What it does |
|---|---------|--------------|
| F16 | Settings search command | `workbench.openSettings` (`Ctrl+,`) opens a searchable settings overlay (reuse command palette list). |
| F17 | Hot-reload keybindings | Watch `keybindings.toml` mtime and reload without restart. |
| F18 | Editor config knobs | `wordWrap`, `showLineNumbers`, `tabSize`, `useSpaces` editable from settings and applied live. |

### 4.4 Git Enhancements

Git already supports stage/unstage/discard, commit message input, branch switch, and side-by-side diff. These items add hunk-level convenience.

| # | Feature | What it does |
|---|---------|--------------|
| F19 | Inline diff hunks | Click a changed-line gutter marker to show old vs new inline popover. **TODO / deferred**: needs popover/overlay primitive. See [drift-editor/drift#22](https://github.com/drift-editor/drift/issues/22). |
| F20 | Copy diff hunk | Command/shortcut to copy old or new hunk text. |
| F21 | Revert hunk | Right-click hunk → "Revert hunk" discards changes in that hunk only. |

### 4.5 Terminal

| # | Feature | What it does |
|---|---------|--------------|
| F22 | Multiple terminal tabs | Bottom panel tabs for terminal instances. **TODO / deferred**: requires uirelays Terminal widget multi-session support. See [drift-editor/drift#21](https://github.com/drift-editor/drift/issues/21). |
| F23 | Terminal copy-on-select | Auto-copy selection to clipboard. **TODO / deferred**: requires uirelays Terminal widget API. See [drift-editor/drift#21](https://github.com/drift-editor/drift/issues/21). |

---

## 5. What Is Explicitly Out of Scope

To respect the "no major changes, especially UI" constraint:

- New top-level panels or redesign of sidebar/bottom panel.
- Multi-window / multi-workspace support.
- Plugin/extension marketplace.
- Full VI/Helix modal editing mode.
- Rewriting `app.nim` god object or introducing a retained scene graph.
- Replacing `uirelays`.
- Cloud sync or real-time collaboration.

---

## 6. Phasing

### Phase 1 — Editor Fit-and-Finish (1–2 weeks)
- D4 auto-save, D5 reload conflict prompt
- D8 dirty indicator, D12 reopen closed tab
- D13–D17 search polish and async workspace search
- *(Deferred: D1, D2, D3, D9 until uirelays issues are resolved)*

### Phase 2 — LSP Essentials (2–3 weeks)
- F3/F4 formatting
- F5 rename
- F6 references
- Make LSP language-agnostic per configured server table
- *(Deferred: F1 completion, F2 signature help until uirelays issues #13/#14)*

### Phase 3 — Navigation, Symbols & Debug (1–2 weeks)
- F7 document symbols, F8 workspace symbols
- F13–F15 debug variables/evaluate/setVariable
- *(Deferred: F9 code actions, F10 folding, F11 selection ranges, F12 document highlight, D2 matching bracket jump)*

### Phase 4 — Config, Git & Terminal Polish (1 week)
- F16–F18 settings overlay, keybindings hot-reload, editor config knobs
- D18–D21 status bar/tooltip polish
- *(Deferred: F19 inline diff hunks, F20/F21 hunk copy/revert can proceed without UI changes once hunk parsing exists, F22/F23 terminal tabs/copy-on-select)*

---

## 7. Success Criteria

- All new features are toggleable and default-off or safe-on.
- Existing tests pass; new tests added for `document` text-edit application, `lsp_client` message parsing, and debug variable parsing.
- No new top-level UI panels are introduced.
- LSP formatting/rename/references/symbols work for Nim and can be configured for other languages.
- Debug variables/scopes are visible when stopped at a breakpoint.
- Build command `nim c -o:drift src/drift.nim` succeeds on macOS and Linux after each phase.

---

## 8. Reference Editors

- **Zed**: native speed, agentic AI, LSP-first, multiplayer.
- **Helix/Kakoune**: selection-first modal editing, tree-sitter structural navigation.
- **VS Code**: expansive LSP/AI/extension ecosystem.
- **Micro / Moe**: terminal editors showing baseline expectations (auto-close, LSP, git, config hot-reload).

Drift's differentiator remains a lightweight, Nim-native GUI editor with integrated AI and debugging. These specs fill the gaps that make it a practical daily driver without changing that identity.

---

## 9. Deferred / uirelays-Dependent Features

These items are blocked until `uirelays` (the fork `bung87/uirelays#tmp2`) provides the necessary widget/overlay/API support. Each has a corresponding GitHub issue for tracking.

| Spec # | Feature | Blocker | GitHub Issue |
|--------|---------|---------|--------------|
| D1/D2 | Bracket/quote match highlight and jump-to-match | SynEdit bracket-match API completeness | [#19](https://github.com/drift-editor/drift/issues/19) |
| D3 | Smart auto-indent hooks | SynEdit indent hooks / `additionalIndentChars` extensibility | [#20](https://github.com/drift-editor/drift/issues/20) |
| D9 | Tab close on middle-click | Middle-mouse event delivery across backends | [#23](https://github.com/drift-editor/drift/issues/23) |
| F1 | LSP completion popup | Completion popup widget / SynEdit overlay | [#13](https://github.com/drift-editor/drift/issues/13) |
| F2 | LSP signature help tooltip | Signature-help tooltip / active parameter highlighting | [#14](https://github.com/drift-editor/drift/issues/14) |
| F9 | LSP code actions lightbulb | Gutter/inline hint API and position-anchored context menu | [#15](https://github.com/drift-editor/drift/issues/15) |
| F10 | LSP folding ranges | SynEdit folding primitives (fold state, collapsed rendering) | [#16](https://github.com/drift-editor/drift/issues/16) |
| F11 | LSP selection ranges | SynEdit selection-range expansion API | [#17](https://github.com/drift-editor/drift/issues/17) |
| F12 | Document highlight / occurrences | Document-highlight marker/overlay API | [#18](https://github.com/drift-editor/drift/issues/18) |
| F19 | Inline diff hunk popover | Popover/overlay primitive | [#22](https://github.com/drift-editor/drift/issues/22) |
| F22/F23 | Terminal multi-tab and copy-on-select | Terminal widget multi-session/selection API | [#21](https://github.com/drift-editor/drift/issues/21) |

Until these issues are resolved, implementation in Drift should not modify `uirelays` source as a shortcut; the features should remain in the specs as deferred work.

---

## 10. What Can Be Implemented Now

After deferring the uirelays-dependent items, the following remain as the immediate, self-contained roadmap:

**Phase 1:** D4, D5, D6, D7, D8, D10, D11, D12, D13, D14, D15, D16, D17  
**Phase 2:** F3, F4, F5, F6, F7, F8 + LSP language-agnostic config  
**Phase 3:** F13, F14, F15  
**Phase 4:** F16, F17, F18, F20, F21, D18, D19, D20, D21, D22, D23

These changes stay entirely within the Drift codebase and existing UI layout.

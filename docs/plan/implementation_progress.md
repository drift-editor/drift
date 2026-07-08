# Drift Enhancement Implementation Progress

> This document tracks the implementation status of specs defined in `enhancement_specs.md`.
> Last updated: 2026-07-08

## Recent Completion Snapshot

The following features were implemented in the current development push (most recent first). All changes are local-only and have not been pushed.

| Spec | Feature | Commit | Notes |
|------|---------|--------|-------|
| D1 | Bracket/quote match highlight | `501e389` | Implemented via editor markers; highlights matching `()[]{}` when cursor is adjacent. |
| D2 | Jump to matching bracket | `158b907` | Command `navigate.matchingBracket` moves cursor to the paired bracket. |
| D9 | Tab close on middle-click | `8421066` | Middle mouse button closes a tab. |
| D22 | Argument-aware command palette commands | `bbcf3c1` | Commands like `>Go to Line: 42` accepted from the palette. |
| — | AI chat scroll performance | `18e57f1` | Caches AI chat bubble layouts to reduce repeated measurement during scroll. Not a numbered spec. |
| F15 | Set variable value in debug panel | `c5ffa9a` | Double-click a variable value to edit and send DAP `setVariable`. |
| F16 | Searchable settings command | `28542a0` | `Ctrl+,` opens a searchable settings overlay. |
| F20 | Copy diff hunk | `6049893` | Command/shortcut copies old or new hunk text. |
| F21 | Revert hunk | `6049893` | Right-click hunk → "Revert hunk" discards changes in that hunk only. |
| F14 | Evaluate expression in debug panel | `e89b242` | DAP `evaluate` request bound to a bottom-panel input. |
| F13 | Debug variables/scopes tree | `e1e9d89` | Wires `dmkVariablesResponse` into `debug_panel.nim` with expandable tree. |
| F17 | Hot-reload keybindings | `e1e9d89` | Watches `keybindings.toml` mtime and reloads without restart. |
| F3 | Format document | `e356503` | `Shift+Alt+F` via LSP `textDocument/formatting`. |
| F4 | Format selection | `e356503` | LSP `textDocument/rangeFormatting` when selection active. |
| F5 | Rename symbol | `e356503` | `F2` with input dialog; applies workspace edit. |
| F6 | Find references | `e356503` | `Shift+F12`; results shown in location picker. |
| F7 | Document symbols | `e356503` | `Ctrl+Shift+O` fuzzy picker. |
| F8 | Workspace symbols | `e356503` | `Ctrl+T`. |
| — | LSP language-agnostic config | `e356503` | `lspServers` table maps language ids to server commands. |
| D20 | LSP status hover | `e356503` | Hover status bar LSP icon shows server name + ready/error message. |
| D23 | Recently used commands | `e356503` | Command palette sorts recently executed commands higher. |

## Overall Status

| Spec | Feature | Status | Commit / Issue | Notes |
|------|---------|--------|----------------|-------|
| **D1** | Bracket/quote match highlight | ✅ Implemented | `501e389` | |
| **D2** | Jump to matching bracket | ✅ Implemented | `158b907` | |
| **D3** | Smart auto-indent | ⏸️ Deferred | drift-editor/drift#28 | Needs SynEdit indent hooks. |
| **D4** | Auto-save | ⏳ Not started | — | |
| **D5** | Auto-reload changed files | ⏳ Not started | — | |
| **D6** | Duplicate selection | ⏳ Not started | — | |
| **D7** | Cycle clipboard ring | ⏳ Not started | — | |
| **D8** | Unsaved-change indicator | ⏳ Not started | — | |
| **D9** | Tab close on middle-click | ✅ Implemented | `8421066` | |
| **D10** | Recent-file path tooltip | ⏳ Not started | — | |
| **D11** | Pinned recent files | ⏳ Not started | — | |
| **D12** | Reopen closed tab | ⏳ Not started | — | |
| **D13** | Persist search options | ⏳ Not started | — | |
| **D14** | Find result counter | ⏳ Not started | — | |
| **D15** | Search history | ⏳ Not started | — | |
| **D16** | Workspace search async | ⏳ Not started | — | |
| **D17** | Global find results panel | ⏳ Not started | — | |
| **D18** | Line ending display | ⏳ Not started | — | |
| **D19** | Encoding display | ⏳ Not started | — | |
| **D20** | LSP status hover | ✅ Implemented | `e356503` | |
| **D21** | Hover tooltip markdown | ⏭️ Skipped | — | Explicitly skipped by user. |
| **D22** | Argument-aware commands | ✅ Implemented | `bbcf3c1` | |
| **D23** | Recently used commands | ✅ Implemented | `e356503` | |
| **F1** | LSP completion | ⏸️ Deferred | drift-editor/drift#28 | Needs completion popup widget. |
| **F2** | LSP signature help | ⏸️ Deferred | drift-editor/drift#28 | Needs signature-help tooltip. |
| **F3** | LSP format document | ✅ Implemented | `e356503` | |
| **F4** | LSP format selection | ✅ Implemented | `e356503` | |
| **F5** | LSP rename symbol | ✅ Implemented | `e356503` | |
| **F6** | LSP find references | ✅ Implemented | `e356503` | |
| **F7** | LSP document symbols | ✅ Implemented | `e356503` | |
| **F8** | LSP workspace symbols | ✅ Implemented | `e356503` | |
| **F9** | LSP code actions | ⏸️ Deferred | drift-editor/drift#28 | Needs gutter/inline hint API. |
| **F10** | LSP folding ranges | ⏸️ Deferred | drift-editor/drift#28 | Needs SynEdit folding primitives. |
| **F11** | LSP selection ranges | ⏸️ Deferred | drift-editor/drift#28 | Needs selection-range API. |
| **F12** | LSP document highlight | ⏸️ Deferred | drift-editor/drift#28 | Needs document-highlight marker API. |
| **F13** | Debug variables/scopes tree | ✅ Implemented | `e1e9d89` | |
| **F14** | Debug evaluate expression | ✅ Implemented | `e89b242` | |
| **F15** | Debug set variable value | ✅ Implemented | `c5ffa9a` | |
| **F16** | Searchable settings command | ✅ Implemented | `28542a0` | |
| **F17** | Hot-reload keybindings | ✅ Implemented | `e1e9d89` | |
| **F18** | Editor config knobs | ⚠️ Partial | — | `tabSize` and `showLineNumbers` implemented in settings picker. `wordWrap` and `useSpaces` deferred (drift-editor/drift#28). |
| **F19** | Inline diff hunks | ⏸️ Deferred | drift-editor/drift#28 | Needs popover/overlay primitive. |
| **F20** | Copy diff hunk | ✅ Implemented | `6049893` | |
| **F21** | Revert hunk | ✅ Implemented | `6049893` | |
| **F22** | Multiple terminal tabs | ⏸️ Deferred | drift-editor/drift#28 | Needs Terminal widget multi-session support. |
| **F23** | Terminal copy-on-select | ⏸️ Deferred | drift-editor/drift#28 | Needs Terminal widget API. |

## Deferred / uirelays-Dependent Items

All deferred features are tracked in [drift-editor/drift#28](https://github.com/drift-editor/drift/issues/28):

- D3 Smart auto-indent
- F1 LSP completion
- F2 LSP signature help
- F9 LSP code actions
- F10 LSP folding ranges
- F11 LSP selection ranges
- F12 LSP document highlight
- F18 `wordWrap` / `useSpaces` toggles
- F19 Inline diff hunks
- F22 Multiple terminal tabs
- F23 Terminal copy-on-select

## Build Verification

- Last successful build: `nim c -o:drift src/drift.nim` (SuccessX, ~188496 lines) after `501e389`.
- No commits have been pushed yet.

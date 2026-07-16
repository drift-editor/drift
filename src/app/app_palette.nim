## Command palette command registrations
##
## Extracted from app.nim's init() so the (large) list of palette commands
## lives in its own file. We use a template with an `untyped app` parameter so
## the body is instantiated in app.nim's scope, where the `App` type and all
## widget procs are visible — this avoids a circular import.

template registerPaletteCommands*(app: untyped): untyped =
  app.commandPalette.clearCommands()
  app.commandPalette.registerCommand("workbench.openSettings", "Open Settings", "Search and edit user settings", ccView, "Ctrl+,",
    proc() =
      app.commandPalette.switchToSettingsMode(app.buildSettingsItems())
      app.commandPalette.show()
      if app.tooltip.visible: app.tooltip.hideTooltip())
  app.commandPalette.registerCommand("file.new", "New File", "Create a new file", ccFile, "Ctrl+N",
    proc() = app.newFile())
  app.commandPalette.registerCommand("file.open", "Open File", "Open an existing file", ccFile, "Ctrl+O",
    proc() = discard app.openFileDialog(),
    proc(arg: string) =
      if arg.len == 0:
        return
      let root = if app.fileExplorer.rootPath.len > 0: app.fileExplorer.rootPath else: getCurrentDir()
      let path = if arg.isAbsolute: arg else: root / arg
      if fileExists(path):
        discard app.openBuffer(path)
        app.addRecentFile(path)
      else:
        discard app.notificationManager.error("File not found: " & path))
  app.commandPalette.registerCommand("file.save", "Save", "Save current file", ccFile, "Ctrl+S",
    proc() = discard app.saveCurrentBuffer())
  app.commandPalette.registerCommand("file.saveAs", "Save As...", "Save with a new name", ccFile, "Ctrl+Shift+S",
    proc() = app.saveAsDialog())
  app.commandPalette.registerCommand("file.close", "Close Tab", "Close current tab", ccFile, "Ctrl+W",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.closeBuffer(app.currentBuffer))
  app.commandPalette.registerCommand("view.toggleSidebar", "Toggle Sidebar", "Show or hide the sidebar", ccView, "Ctrl+B",
    proc() = app.sidebarVisible = not app.sidebarVisible)
  app.commandPalette.registerCommand("view.toggleTerminal", "Toggle Terminal", "Show or hide the terminal", ccView, "Ctrl+T",
    proc() =
      app.showTerminal = not app.showTerminal
      if app.showTerminal: app.focus = "term" else: app.focus = "editor")
  app.commandPalette.registerCommand("git.reviewChanges", "Review Changes", "Send local git changes to AI for review", ccGit, "Ctrl+Shift+R",
    proc() = app.reviewChanges())
  app.commandPalette.registerCommand("git.copyOldHunk", "Copy Old Hunk", "Copy the original text of the diff hunk at the cursor line", ccGit, "",
    proc() = app.copyOldHunk())
  app.commandPalette.registerCommand("git.copyNewHunk", "Copy New Hunk", "Copy the changed text of the diff hunk at the cursor line", ccGit, "",
    proc() = app.copyNewHunk())
  app.commandPalette.registerCommand("git.revertHunk", "Revert Hunk", "Revert the unstaged diff hunk at the cursor line", ccGit, "",
    proc() = app.revertCurrentHunk())
  app.commandPalette.registerCommand("view.toggleGit", "Toggle Git Panel", "Show or hide the Git panel", ccView, "Ctrl+Shift+G",
    proc() =
      app.showGitPanel = not app.showGitPanel
      app.showSearchPanel = false
      app.showDebugPanel = false
      if app.showGitPanel:
        app.sidebarVisible = true
        app.gitPanel.updateRepository())
  app.commandPalette.registerCommand("view.toggleProblems", "Toggle Problems Panel", "Show the Problems panel in the bottom panel", ccView, "Ctrl+Shift+M",
    proc() =
      app.showTerminal = true
      app.bottomPanelTab = "problems")
  app.commandPalette.registerCommand("search.find", "Find", "Find in current file", ccSearch, "Ctrl+F",
    proc() =
      let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
      app.searchPanel.show(ed))
  app.commandPalette.registerCommand("search.replace", "Replace", "Find and replace in current file", ccSearch, "Ctrl+H",
    proc() =
      let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
      app.searchPanel.show(ed, focusReplace = true))
  app.commandPalette.registerCommand("search.findInWorkspace", "Find in Workspace", "Search across all files in the workspace", ccSearch, "Ctrl+Shift+F",
    proc() =
      app.showSearchPanel = true
      app.showGitPanel = false
      app.showDebugPanel = false
      app.sidebarVisible = true
      app.searchPanel.mode = smWorkspace
      let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
      app.searchPanel.show(ed))
  app.commandPalette.registerCommand("edit.undo", "Undo", "Undo last action", ccEdit, "Ctrl+Z",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.undo())
  app.commandPalette.registerCommand("edit.redo", "Redo", "Redo last undone action", ccEdit, "Ctrl+Y",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.redo())
  app.commandPalette.registerCommand("edit.deleteLine", "Delete Line", "Delete the current line", ccEdit, "Ctrl+Shift+K",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.deleteLine())
  app.commandPalette.registerCommand("edit.duplicateLine", "Duplicate Line", "Duplicate the current line", ccEdit, "Ctrl+Shift+D",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.duplicateLine())
  app.commandPalette.registerCommand("edit.moveLineUp", "Move Line Up", "Move current line up", ccEdit, "Alt+Up",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.moveLineUp())
  app.commandPalette.registerCommand("edit.moveLineDown", "Move Line Down", "Move current line down", ccEdit, "Alt+Down",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.moveLineDown())
  app.commandPalette.registerCommand("edit.insertLineAbove", "Insert Line Above", "Insert a new line above", ccEdit, "Ctrl+Shift+Enter",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.insertLineAbove())
  app.commandPalette.registerCommand("edit.insertLineBelow", "Insert Line Below", "Insert a new line below", ccEdit, "Ctrl+Enter",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.insertLineBelow())
  app.commandPalette.registerCommand("edit.joinLines", "Join Lines", "Join current line with the next", ccEdit, "Ctrl+J",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.joinLines())
  app.commandPalette.registerCommand("edit.toggleComment", "Toggle Line Comment", "Comment or uncomment the current line", ccEdit, "Ctrl+/",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.toggleComment())
  app.commandPalette.registerCommand("edit.selectLine", "Select Line", "Select the current line", ccEdit, "Ctrl+L",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.selectLine())
  app.commandPalette.registerCommand("edit.duplicateSelection", "Duplicate Selection", "Duplicate selection or current line", ccEdit, "Ctrl+D",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        let ed = addr app.buffers[app.currentBuffer].ed
        let sel = ed[].getSelectedText()
        if sel.len > 0:
          ed[].insertText(sel & sel)
        else:
          ed[].duplicateLine())
  app.commandPalette.registerCommand("edit.copy", "Copy", "Copy selection to clipboard", ccEdit, "Ctrl+C",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        let text = app.buffers[app.currentBuffer].ed.getSelectedText()
        if text.len > 0:
          putClipboardText(text)
          app.pushClipboardHistory(text))
  app.commandPalette.registerCommand("edit.cut", "Cut", "Cut selection to clipboard", ccEdit, "Ctrl+X",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        let text = app.buffers[app.currentBuffer].ed.getSelectedText()
        if text.len > 0:
          putClipboardText(text)
          app.pushClipboardHistory(text)
          app.buffers[app.currentBuffer].ed.insertText(""))
  app.commandPalette.registerCommand("edit.cycleClipboard", "Cycle Clipboard", "Cycle through clipboard history", ccEdit, "Ctrl+Shift+V",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        let ed = addr app.buffers[app.currentBuffer].ed
        if app.clipboardHistory.len == 0:
          let clip = getClipboardText()
          if clip.len > 0:
            app.pushClipboardHistory(clip)
        if app.clipboardHistory.len > 0:
          let idx = app.clipboardHistoryIndex mod app.clipboardHistory.len
          ed[].insertText(app.clipboardHistory[idx])
          app.clipboardHistoryIndex = (app.clipboardHistoryIndex + 1) mod app.clipboardHistory.len)
  app.commandPalette.registerCommand("file.reopenClosedTab", "Reopen Closed Tab", "Reopen the most recently closed tab", ccFile, "Ctrl+Shift+T",
    proc() =
      if app.closedTabs.len > 0:
        let info = app.closedTabs.pop()
        let idx = app.openBuffer(info.path)
        if idx >= 0 and idx < app.buffers.len:
          app.buffers[idx].ed.gotoLine(info.line + 1, info.col))
  app.commandPalette.registerCommand("file.newNamed", "New File Named...", "Create a new file with a given name", ccFile, "",
    proc() =
      app.inputDialog.title = "New File"
      app.inputDialog.prompt = "Enter file name:"
      app.inputDialog.text = ""
      app.inputDialog.centerOnScreen(app.width, app.height)
      app.inputDialog.onResult = proc(confirmed: bool, text: string) =
        if confirmed and text.len > 0:
          let root = if app.fileExplorer.rootPath.len > 0: app.fileExplorer.rootPath else: getCurrentDir()
          let newPath = root / text
          try:
            writeFile(newPath, "")
            discard app.openBuffer(newPath)
            app.addRecentFile(newPath)
          except CatchableError as err:
            discard app.notificationManager.error("Failed to create file: " & err.msg)
      app.inputDialog.show(),
    proc(arg: string) =
      if arg.len == 0:
        return
      let root = if app.fileExplorer.rootPath.len > 0: app.fileExplorer.rootPath else: getCurrentDir()
      let newPath = if arg.isAbsolute: arg else: root / arg
      try:
        writeFile(newPath, "")
        discard app.openBuffer(newPath)
        app.addRecentFile(newPath)
      except CatchableError as err:
        discard app.notificationManager.error("Failed to create file: " & err.msg))
  app.commandPalette.registerCommand("file.openFolder", "Open Folder...", "Open a workspace folder", ccFile, "",
    proc() =
      discard app.openFolderDialog())
  app.commandPalette.registerCommand("file.saveAs", "Save As...", "Save current file with a new name", ccFile, "Ctrl+Shift+S",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        let b = app.buffers[app.currentBuffer]
        if b.path.len > 0:
          app.inputDialog.title = "Save As"
          app.inputDialog.prompt = "Enter new file name:"
          app.inputDialog.text = b.path.extractFilename
          app.inputDialog.centerOnScreen(app.width, app.height)
          app.inputDialog.onResult = proc(confirmed: bool, text: string) =
            if confirmed and text.len > 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
              let root = b.path.parentDir
              let newPath = root / text
              try:
                writeFile(newPath, b.ed.fullText)
                app.buffers[app.currentBuffer].path = newPath
                app.buffers[app.currentBuffer].lastSaveTick = getTicks()
                app.buffers[app.currentBuffer].lastChanged = false
                app.tabBar.updateTabModified($app.currentBuffer, false)
                app.updateTitle()
                app.updateStatus()
                app.addRecentFile(newPath)
              except CatchableError as err:
                discard app.notificationManager.error("Failed to save file: " & err.msg)
          app.inputDialog.show())
  app.commandPalette.registerCommand("navigate.gotoLine", "Go to Line...", "Jump to a specific line number", ccView, "Ctrl+G",
    proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.inputDialog.title = "Go to Line"
        app.inputDialog.prompt = "Enter line number:"
        app.inputDialog.text = ""
        app.inputDialog.centerOnScreen(app.width, app.height)
        app.inputDialog.onResult = proc(confirmed: bool, text: string) =
          if confirmed and text.len > 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
            try:
              let lineNum = parseInt(text)
              app.buffers[app.currentBuffer].ed.gotoLine(lineNum, 0)
            except ValueError:
              discard
        app.inputDialog.show(),
    proc(arg: string) =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len or arg.len == 0:
        return
      try:
        let lineNum = parseInt(arg)
        app.buffers[app.currentBuffer].ed.gotoLine(lineNum, 0)
      except ValueError:
        discard)
  app.commandPalette.registerCommand("palette.show", "Command Palette", "Show command palette", ccView, "Ctrl+Shift+P",
    proc() =
      app.commandPalette.switchToCommandMode()
      app.commandPalette.show())

  # Settings picker: open input dialog for numeric/string settings
  app.commandPalette.onSettingSelect = proc(item: SettingItem) =
    case item.kind
    of skInt:
      app.inputDialog.title = item.label
      app.inputDialog.prompt = "Enter new value for " & item.key & ":"
      app.inputDialog.text = item.getValue()
      app.inputDialog.centerOnScreen(app.width, app.height)
      app.inputDialog.onResult = proc(confirmed: bool, text: string) =
        if confirmed and item.setValue != nil:
          item.setValue(text)
      app.inputDialog.show()
    of skString:
      app.inputDialog.title = item.label
      app.inputDialog.prompt = "Enter new value for " & item.key & ":"
      app.inputDialog.text = item.getValue()
      app.inputDialog.centerOnScreen(app.width, app.height)
      app.inputDialog.onResult = proc(confirmed: bool, text: string) =
        if confirmed and item.setValue != nil:
          item.setValue(text)
      app.inputDialog.show()
    else:
      discard

  # Theme selector
  app.themeSelector.onPreview = proc(name: string) =
    app.setTheme(name)
  app.themeSelector.onApply = proc(name: string) =
    app.applyTheme(name)
  app.themeSelector.onCancel = proc() =
    app.setTheme(app.config.theme)
  app.commandPalette.registerCommand("theme.selector", "Color Theme", "Open theme selector", ccView, "",
    proc() =
      app.themeSelector.show(app.config.theme))

  # Debug commands
  app.commandPalette.registerCommand("debug.start", "Start Debugging", "Start or continue a debug session", ccDebug, "F5",
    proc() = app.startOrContinueDebugging())

  app.commandPalette.registerCommand("debug.continue", "Continue", "Continue execution", ccDebug, "",
    proc() = app.continueDebugging())

  app.commandPalette.registerCommand("debug.stop", "Stop Debugging", "Stop the current debug session", ccDebug, "Shift+F5",
    proc() = app.stopDebugging())

  app.commandPalette.registerCommand("debug.stepOver", "Step Over", "Step over the current line", ccDebug, "F10",
    proc() = app.stepOverDebugging())

  app.commandPalette.registerCommand("debug.stepInto", "Step Into", "Step into the current function", ccDebug, "F11",
    proc() = app.stepIntoDebugging())

  app.commandPalette.registerCommand("debug.stepOut", "Step Out", "Step out of the current function", ccDebug, "Shift+F11",
    proc() = app.stepOutDebugging())

  app.commandPalette.registerCommand("debug.toggleBreakpoint", "Toggle Breakpoint", "Toggle breakpoint on current line", ccDebug, "F9",
    proc() = app.toggleBreakpoint())

  app.commandPalette.registerCommand("view.toggleDebug", "Toggle Debug Panel", "Show the Debug panel in the bottom panel", ccView, "Ctrl+Shift+D",
    proc() =
      app.showTerminal = true
      app.bottomPanelTab = "debug")

  app.commandPalette.registerCommand("editor.toggleBracketHighlight", "Toggle Bracket Highlighting", "Show or hide matching bracket highlight", ccEdit, "",
    proc() =
      app.config.bracketHighlight = not app.config.bracketHighlight
      for i in 0 ..< app.buffers.len:
        app.buffers[i].ed.theme = app.editorTheme()
      saveAppConfig(app))

  app.commandPalette.registerCommand("editor.toggleAutoIndent", "Toggle Auto Indent", "Enable or disable smart auto-indent on Enter", ccEdit, "",
    proc() =
      app.config.autoIndent = not app.config.autoIndent
      saveAppConfig(app))

  app.commandPalette.registerCommand("editor.toggleAutoClose", "Toggle Auto Close Brackets", "Enable or disable auto-closing of brackets and quotes", ccEdit, "",
    proc() =
      app.config.autoCloseBrackets = not app.config.autoCloseBrackets
      saveAppConfig(app))

  app.commandPalette.registerCommand("editor.toggleLineNumbers", "Toggle Line Numbers", "Show or hide editor line numbers", ccEdit, "",
    proc() =
      app.config.showLineNumbers = not app.config.showLineNumbers
      for i in 0 ..< app.buffers.len:
        if not app.buffers[i].isImage:
          app.buffers[i].ed.showLineNumbers = app.config.showLineNumbers
      saveAppConfig(app))

  app.commandPalette.registerCommand("editor.increaseTabSize", "Increase Tab Size", "Increase editor indentation width", ccEdit, "",
    proc() =
      if app.config.tabSize < 8:
        app.config.tabSize += 1
        for i in 0 ..< app.buffers.len:
          if not app.buffers[i].isImage:
            app.buffers[i].ed.tabSize = app.config.tabSize
        saveAppConfig(app)
        discard app.notificationManager.info("Tab size: " & $app.config.tabSize))

  app.commandPalette.registerCommand("editor.decreaseTabSize", "Decrease Tab Size", "Decrease editor indentation width", ccEdit, "",
    proc() =
      if app.config.tabSize > 1:
        app.config.tabSize -= 1
        for i in 0 ..< app.buffers.len:
          if not app.buffers[i].isImage:
            app.buffers[i].ed.tabSize = app.config.tabSize
        saveAppConfig(app)
        discard app.notificationManager.info("Tab size: " & $app.config.tabSize))
  app.commandPalette.registerCommand("editor.formatDocument", "Format Document", "Format the current document via LSP", ccEdit, "Shift+Alt+F",
    proc() =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      let lang = languageIdFor(b.path)
      if b.path.len == 0 or app.lspServerForLanguage(lang).len == 0:
        discard app.notificationManager.info("Format Document is not available for this file type")
        return
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      app.lspThread.requestFormatting(b.path))

  app.commandPalette.registerCommand("editor.formatSelection", "Format Selection", "Format the current selection via LSP", ccEdit, "",
    proc() =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      let lang = languageIdFor(b.path)
      if b.path.len == 0 or app.lspServerForLanguage(lang).len == 0:
        discard app.notificationManager.info("Format Selection is not available for this file type")
        return
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      let rangeOpt = lspRangeForSelection(b.ed)
      if rangeOpt.isNone:
        discard app.notificationManager.info("No selection to format")
        return
      app.lspThread.requestRangeFormatting(b.path, rangeOpt.get()))

  app.commandPalette.registerCommand("editor.renameSymbol", "Rename Symbol", "Rename the symbol under the cursor via LSP", ccEdit, "F2",
    proc() =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      let lang = languageIdFor(b.path)
      if b.path.len == 0 or app.lspServerForLanguage(lang).len == 0:
        discard app.notificationManager.info("Rename Symbol is not available for this file type")
        return
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      let line = b.ed.currentLine
      let col = b.ed.currentCol
      app.inputDialog.title = "Rename Symbol"
      app.inputDialog.prompt = "Enter new name:"
      app.inputDialog.text = ""
      app.inputDialog.centerOnScreen(app.width, app.height)
      app.inputDialog.onResult = proc(confirmed: bool, text: string) =
        if confirmed and text.len > 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
          app.lspThread.requestRename(b.path, line, col, text)
      app.inputDialog.show())

  app.commandPalette.registerCommand("editor.findReferences", "Find References", "Find all references to the symbol under the cursor via LSP", ccEdit, "Shift+F12",
    proc() =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      let lang = languageIdFor(b.path)
      if b.path.len == 0 or app.lspServerForLanguage(lang).len == 0:
        discard app.notificationManager.info("Find References is not available for this file type")
        return
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      app.lspThread.requestReferences(b.path, b.ed.currentLine, b.ed.currentCol))

  app.commandPalette.registerCommand("workbench.gotoSymbol", "Go to Symbol in File", "List and jump to symbols in the current file via LSP", ccView, "Ctrl+Shift+O",
    proc() =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      let lang = languageIdFor(b.path)
      if b.path.len == 0 or app.lspServerForLanguage(lang).len == 0:
        discard app.notificationManager.info("Go to Symbol is not available for this file type")
        return
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      app.lspThread.requestDocumentSymbols(b.path),
    proc(arg: string) =
      if arg.len == 0:
        return
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      let lang = languageIdFor(b.path)
      if b.path.len == 0 or app.lspServerForLanguage(lang).len == 0:
        discard app.notificationManager.info("Go to Symbol is not available for this file type")
        return
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      # Send the query via LSP workspace symbols as a proxy for filtered document symbols.
      app.lspThread.requestWorkspaceSymbols(arg))

  app.commandPalette.registerCommand("workbench.gotoSymbolInWorkspace", "Go to Symbol in Workspace", "Search and jump to symbols across the workspace via LSP", ccView, "Ctrl+T",
    proc() =
      if app.lspThread == nil or not app.lspThread.isReady.load(moAcquire):
        discard app.notificationManager.info("LSP is not ready")
        return
      app.inputDialog.title = "Go to Symbol in Workspace"
      app.inputDialog.prompt = "Enter symbol name:"
      app.inputDialog.text = ""
      app.inputDialog.centerOnScreen(app.width, app.height)
      app.inputDialog.onResult = proc(confirmed: bool, text: string) =
        if confirmed and text.len > 0:
          app.lspThread.requestWorkspaceSymbols(text)
      app.inputDialog.show())

  app.commandPalette.registerCommand("keybindings.open", "Open Keybindings File", "Edit keybinding overrides in ~/.config/drift/keybindings.toml", ccView, "",
    proc() =
      let kbPath = kb.keybindingsPath()
      kb.ensureDefaultKeybindingsFile(kbPath)
      discard app.openBuffer(kbPath))

  app.commandPalette.onFileSelect = proc(path: string) =
    discard app.openBuffer(path)

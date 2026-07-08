## Command registrations for the editor

import uirelays/input
import commands

# We take an untyped param to avoid a circular import. 
# app.nim calls this with `initCommands(app)`.

template initCommands*(app: untyped): untyped =
  block:
    app.commands = newCommandRegistry()

    # File
    app.commands.bindKey({CtrlPressed}, KeyN, "file.new")
    app.commands.register("file.new") do (): app.newFile()

    app.commands.bindKey({CtrlPressed}, KeyO, "file.open")
    app.commands.register("file.open") do (): discard app.openFileDialog()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyO, "folder.open")
    app.commands.register("folder.open") do (): discard app.openFolderDialog()

    app.commands.bindKey({CtrlPressed}, KeyS, "file.save")
    app.commands.register("file.save") do ():
      if not app.saveCurrentBuffer():
        app.saveAsDialog()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyS, "file.saveAs")
    app.commands.register("file.saveAs") do (): app.saveAsDialog()

    app.commands.bindKey({CtrlPressed}, KeyW, "file.close")
    app.commands.register("file.close") do ():
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and
         app.buffers[app.currentBuffer].diffPath.len > 0:
        app.closeBuffer(app.currentBuffer)
        app.focus = "editor"
      elif app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.closeBuffer(app.currentBuffer)

    # Edit
    app.commands.bindKey({CtrlPressed}, KeyZ, "edit.undo")
    app.commands.register("edit.undo") do ():
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.undo()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyZ, "edit.redo")
    app.commands.bindKey({CtrlPressed}, KeyY, "edit.redo")
    app.commands.register("edit.redo") do ():
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.redo()

    # Find / Search
    app.commands.bindKey({CtrlPressed}, KeyF, "search.find")
    app.commands.bindKey({CtrlPressed}, KeyH, "search.replace")
    app.commands.register("search.find") do ():
      let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
      app.searchPanel.show(ed)
    app.commands.register("search.replace") do ():
      let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
      app.searchPanel.show(ed, focusReplace = true)

    # View
    app.commands.bindKey({CtrlPressed}, KeyB, "view.toggleSidebar")
    app.commands.register("view.toggleSidebar") do ():
      app.sidebarVisible = not app.sidebarVisible

    app.commands.bindKey({CtrlPressed}, KeyT, "view.toggleTerminal")
    app.commands.register("view.toggleTerminal") do ():
      app.showTerminal = not app.showTerminal
      app.focus = if app.showTerminal: "term" else: "editor"

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyG, "view.toggleGit")
    app.commands.register("view.toggleGit") do ():
      app.showGitPanel = not app.showGitPanel
      if app.showGitPanel:
        app.gitPanel.updateRepository()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyR, "git.reviewChanges")
    app.commands.register("git.reviewChanges") do (): app.reviewChanges()

    app.commands.register("git.copyOldHunk") do (): app.copyOldHunk()
    app.commands.register("git.copyNewHunk") do (): app.copyNewHunk()
    app.commands.register("git.revertHunk") do (): app.revertCurrentHunk()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyM, "view.toggleProblems")
    app.commands.register("view.toggleProblems") do ():
      app.showTerminal = true
      app.bottomPanelTab = "problems"

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyA, "view.toggleAIPanel")
    app.commands.register("view.toggleAIPanel") do ():
      app.aiPanelVisible = not app.aiPanelVisible
      if app.aiPanelVisible:
        app.focus = "aiPanel"
        app.aiPanel.focused = true
      elif app.focus == "aiPanel":
        app.focus = "editor"

    # Command palette
    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyP, "workbench.showCommands")
    app.commands.register("workbench.showCommands") do ():
      app.commandPalette.switchToCommandMode()
      app.commandPalette.show()
      if app.tooltip.visible: app.tooltip.hideTooltip()

    app.commands.bindKey({CtrlPressed}, KeyP, "workbench.quickOpen")
    app.commands.register("workbench.quickOpen") do ():
      app.commandPalette.switchToFileMode(app.buildQuickOpenFiles())
      app.commandPalette.show()
      if app.tooltip.visible: app.tooltip.hideTooltip()

    # Theme selector (no default keybinding; shortcut reused for reopen closed tab)
    app.commands.register("theme.selector") do ():
      app.themeSelector.show(app.config.themeName)
      if app.tooltip.visible: app.tooltip.hideTooltip()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyT, "file.reopenClosedTab")
    app.commands.register("file.reopenClosedTab") do ():
      if app.closedTabs.len > 0:
        let info = app.closedTabs.pop()
        let idx = app.openBuffer(info.path)
        if idx >= 0 and idx < app.buffers.len:
          app.buffers[idx].ed.gotoLine(info.line + 1, info.col)

    # AI Review Changes
    app.commands.register("ai.reviewChanges") do ():
      app.reviewChanges()

    # Editor line operations
    template withEd(body: untyped): untyped =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        template ed: untyped = app.buffers[app.currentBuffer].ed
        body

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyK, "edit.deleteLine")
    app.commands.register("edit.deleteLine") do ():
      withEd: ed.deleteLine()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyD, "edit.duplicateLine")
    app.commands.register("edit.duplicateLine") do ():
      withEd: ed.duplicateLine()

    app.commands.bindKey({AltPressed}, KeyUp, "edit.moveLineUp")
    app.commands.register("edit.moveLineUp") do ():
      withEd: ed.moveLineUp()

    app.commands.bindKey({AltPressed}, KeyDown, "edit.moveLineDown")
    app.commands.register("edit.moveLineDown") do ():
      withEd: ed.moveLineDown()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyEnter, "edit.insertLineAbove")
    app.commands.register("edit.insertLineAbove") do ():
      withEd: ed.insertLineAbove()

    app.commands.bindKey({CtrlPressed}, KeyEnter, "edit.insertLineBelow")
    app.commands.register("edit.insertLineBelow") do ():
      withEd: ed.insertLineBelow()

    app.commands.bindKey({CtrlPressed}, KeyJ, "edit.joinLines")
    app.commands.register("edit.joinLines") do ():
      withEd: ed.joinLines()

    app.commands.bindKey({CtrlPressed}, KeySlash, "edit.toggleComment")
    app.commands.register("edit.toggleComment") do ():
      withEd: ed.toggleComment()

    app.commands.bindKey({CtrlPressed}, KeyL, "edit.selectLine")
    app.commands.register("edit.selectLine") do ():
      withEd: ed.selectLine()

    app.commands.bindKey({CtrlPressed}, KeyD, "edit.duplicateSelection")
    app.commands.register("edit.duplicateSelection") do ():
      withEd:
        let sel = ed.getSelectedText()
        if sel.len > 0:
          ed.insertText(sel & sel)
        else:
          ed.duplicateLine()

    app.commands.bindKey({CtrlPressed}, KeyC, "edit.copy")
    app.commands.register("edit.copy") do ():
      withEd:
        let text = ed.getSelectedText()
        if text.len > 0:
          putClipboardText(text)
          app.pushClipboardHistory(text)

    app.commands.bindKey({CtrlPressed}, KeyX, "edit.cut")
    app.commands.register("edit.cut") do ():
      withEd:
        let text = ed.getSelectedText()
        if text.len > 0:
          putClipboardText(text)
          app.pushClipboardHistory(text)
          ed.insertText("")

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyV, "edit.cycleClipboard")
    app.commands.register("edit.cycleClipboard") do ():
      withEd:
        if app.clipboardHistory.len == 0:
          let clip = getClipboardText()
          if clip.len > 0:
            app.pushClipboardHistory(clip)
        if app.clipboardHistory.len > 0:
          let idx = app.clipboardHistoryIndex mod app.clipboardHistory.len
          ed.insertText(app.clipboardHistory[idx])
          app.clipboardHistoryIndex = (app.clipboardHistoryIndex + 1) mod app.clipboardHistory.len

    app.commands.bindKey({CtrlPressed}, KeyG, "navigate.gotoLine")
    app.commands.register("navigate.gotoLine") do ():
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
        app.inputDialog.show()

    # Debug
    app.commands.bindKey({}, KeyF5, "debug.start")
    app.commands.register("debug.start") do (): app.startOrContinueDebugging()

    app.commands.bindKey({ShiftPressed}, KeyF5, "debug.stop")
    app.commands.register("debug.stop") do (): app.stopDebugging()

    app.commands.bindKey({}, KeyF10, "debug.stepOver")
    app.commands.register("debug.stepOver") do (): app.stepOverDebugging()

    app.commands.bindKey({}, KeyF11, "debug.stepInto")
    app.commands.register("debug.stepInto") do (): app.stepIntoDebugging()

    app.commands.bindKey({ShiftPressed}, KeyF11, "debug.stepOut")
    app.commands.register("debug.stepOut") do (): app.stepOutDebugging()

    app.commands.bindKey({}, KeyF9, "debug.toggleBreakpoint")
    app.commands.register("debug.toggleBreakpoint") do (): app.toggleBreakpoint()

    app.commands.bindKey({CtrlPressed, ShiftPressed}, KeyD, "view.toggleDebug")
    app.commands.register("view.toggleDebug") do ():
      app.showTerminal = true
      app.bottomPanelTab = "debug"

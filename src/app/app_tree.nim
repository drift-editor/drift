## Build the node tree for event routing

import uirelays
import uirelays/screen
import ../ui/node
import ../ui/[file_explorer, git_panel, search_panel, command_palette, context_menu, welcome_screen, theme_selector, location_picker]
import app_layout


template addOverlays(root, app, layout): untyped =
  if app.themeSelector.isVisible:
    let themeNode = newNode("themeSelector")
    themeNode.bounds = layout.screen
    themeNode.zIndex = 99
    themeNode.onMouseDown = proc(n: Node, e: Event): bool =
      return app.themeSelector.handleInput(e)
    themeNode.onMouseMove = proc(n: Node, e: Event): bool =
      let handled = app.themeSelector.handleInput(e)
      handled
    themeNode.onMouseWheel = proc(n: Node, e: Event): bool =
      return app.themeSelector.handleInput(e)
    themeNode.onKeyDown = proc(n: Node, e: Event): bool =
      return app.themeSelector.handleInput(e)
    themeNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
      if app.themeSelector.hoverIndex >= 0: curHand else: curDefault)
    root.addChild(themeNode)

  if app.commandPalette.isVisible:
    let paletteNode = newNode("commandPalette")
    paletteNode.bounds = layout.screen
    paletteNode.zIndex = 100
    paletteNode.onMouseDown = proc(n: Node, e: Event): bool =
      return app.commandPalette.handleInput(e)
    paletteNode.onMouseMove = proc(n: Node, e: Event): bool =
      let handled = app.commandPalette.handleInput(e)
      handled
    paletteNode.onMouseWheel = proc(n: Node, e: Event): bool =
      return app.commandPalette.handleInput(e)
    paletteNode.onKeyDown = proc(n: Node, e: Event): bool =
      return app.commandPalette.handleInput(e)
    paletteNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
      if app.commandPalette.hoverIndex >= 0: curHand else: curDefault)
    root.addChild(paletteNode)

  if app.contextMenu.isVisible:
    let menuNode = newNode("contextMenu")
    menuNode.bounds = app.contextMenu.bounds
    menuNode.zIndex = 101
    menuNode.onMouseDown = proc(n: Node, e: Event): bool =
      return app.contextMenu.handleInput(e)
    menuNode.onMouseMove = proc(n: Node, e: Event): bool =
      return app.contextMenu.handleInput(e)
    menuNode.onKeyDown = proc(n: Node, e: Event): bool =
      return app.contextMenu.handleInput(e)
    menuNode.setCursorStyle(curHand)
    root.addChild(menuNode)

  if app.lspMenu.isVisible:
    let lspNode = newNode("lspMenu")
    lspNode.bounds = app.lspMenu.bounds
    lspNode.zIndex = 102
    lspNode.onMouseDown = proc(n: Node, e: Event): bool =
      return app.lspMenu.handleInput(e)
    lspNode.onMouseMove = proc(n: Node, e: Event): bool =
      return app.lspMenu.handleInput(e)
    lspNode.onKeyDown = proc(n: Node, e: Event): bool =
      return app.lspMenu.handleInput(e)
    lspNode.setCursorStyle(curHand)
    root.addChild(lspNode)

  if app.locationPicker.isVisible:
    let pickerNode = newNode("locationPicker")
    pickerNode.bounds = app.locationPicker.bounds
    pickerNode.zIndex = 103
    pickerNode.onMouseDown = proc(n: Node, e: Event): bool =
      return app.locationPicker.handleInput(e)
    pickerNode.onMouseMove = proc(n: Node, e: Event): bool =
      let handled = app.locationPicker.handleInput(e)
      handled
    pickerNode.onKeyDown = proc(n: Node, e: Event): bool =
      return app.locationPicker.handleInput(e)
    pickerNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
      if app.locationPicker.hoverIndex >= 0: curHand else: curDefault)
    root.addChild(pickerNode)

template buildWelcomeRoot*(app, layout): Node =
  var root = newNode("welcomeRoot")
  root.bounds = layout.screen
  root.zIndex = 0

  let welcomeNode = newNode("welcomeScreen")
  welcomeNode.bounds = layout.screen
  welcomeNode.zIndex = 1
  welcomeNode.onMouseDown = proc(n: Node, e: Event): bool =
    return app.welcomeScreen.handleMouse(e, app.width, app.height)
  welcomeNode.onMouseMove = proc(n: Node, e: Event): bool =
    discard app.welcomeScreen.handleMouse(e, app.width, app.height)
    true
  welcomeNode.onKeyDown = proc(n: Node, e: Event): bool =
    if e.key == KeyEsc:
      app.hideWelcome()
      return true
    false
  welcomeNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
    for section in app.welcomeScreen.sections:
      for item in section.items:
        if item.isHovered:
          return curHand
    curDefault)
  root.addChild(welcomeNode)

  addOverlays(root, app, layout)
  root

template buildEditorRoot*(app, layout): Node =
  var root = newNode("editorRoot")
  root.bounds = layout.screen
  root.zIndex = 0

  # Editor node
  let editorNode = newNode("editor")
  editorNode.bounds = layout.editor
  editorNode.zIndex = 1
  editorNode.onMouseDown = proc(n: Node, e: Event): bool =
    app.focus = "editor"
    false
  editorNode.onMouseMove = proc(n: Node, e: Event): bool =
    app.focus = "editor"
    # MUST return false. If the event is consumed here, app.nim replaces the
    # real MouseMoveEvent with a NoEvent before passing it to SynEdit.draw().
    # SynEdit then never sets probeActive, never resolves probeResult, and
    # never returns ctrlHover — breaking the entire LSP hover system.
    false
  editorNode.setCursorStyle(curIbeam)
  root.addChild(editorNode)

  # Sidebar resize handle
  if app.sidebarVisible:
    let resizeNode = newNode("sidebarResize")
    resizeNode.bounds = rect(layout.editor.x - 2, TopBarHeight, 4, max(0, layout.screen.h - TopBarHeight - StatusHeight))
    resizeNode.zIndex = 10
    resizeNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.sidebarDragging = true
      app.sidebarDragStartX = e.x
      false
    resizeNode.onMouseMove = proc(n: Node, e: Event): bool =
      true
    resizeNode.setCursorStyle(curSizeWE)
    root.addChild(resizeNode)

  # Sidebar nodes (only one visible at a time)
  if app.sidebarVisible:
    if app.showGitPanel:
      let gitNode = newNode("gitPanel")
      gitNode.bounds = layout.sidebar
      gitNode.zIndex = 2
      gitNode.onMouseDown = proc(n: Node, e: Event): bool =
        app.focus = "git"
        discard app.gitPanel.handleMouse(e, n.bounds)
        false
      gitNode.onMouseMove = proc(n: Node, e: Event): bool =
        discard app.gitPanel.handleMouse(e, n.bounds)
        true
      gitNode.onMouseWheel = proc(n: Node, e: Event): bool =
        discard app.gitPanel.handleMouse(e, n.bounds)
        true
      gitNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
        if app.gitPanel.hoverCommitInput: curIbeam
        elif app.gitPanel.hoverRefresh or app.gitPanel.hoverStagedHeader or app.gitPanel.hoverUnstagedHeader or app.gitPanel.hoverCommitBtn or app.gitPanel.hoverActionKind.len > 0 or app.gitPanel.hoverFilePath.len > 0: curHand
        else: curDefault)
      root.addChild(gitNode)
    elif app.showSearchPanel:
      let searchNode = newNode("searchPanel")
      searchNode.bounds = layout.sidebar
      searchNode.zIndex = 2
      searchNode.onMouseDown = proc(n: Node, e: Event): bool =
        app.focus = "search"
        let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
        return app.searchPanel.handleMouse(ed, e, n.bounds, proc(msg: string) =
          discard app.notificationManager.success(msg))
      searchNode.onMouseMove = proc(n: Node, e: Event): bool =
        let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
        discard app.searchPanel.handleMouse(ed, e, n.bounds, proc(msg: string) = discard)
        false
      searchNode.onMouseWheel = proc(n: Node, e: Event): bool =
        let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
        return app.searchPanel.handleMouse(ed, e, n.bounds, proc(msg: string) = discard)
      searchNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
        if app.searchPanel.hoverInput: curIbeam
        elif app.searchPanel.hoveredButton >= 0 or app.searchPanel.hoveredGroupIndex >= 0 or app.searchPanel.hoveredResult >= 0: curHand
        else: curDefault)
      root.addChild(searchNode)
    elif app.showDebugPanel:
      let debugNode = newNode("debugSidebar")
      debugNode.bounds = layout.sidebar
      debugNode.zIndex = 2
      debugNode.onMouseDown = proc(n: Node, e: Event): bool =
        app.focus = "debug"
        return app.debugSidebar.handleMouse(e, n.bounds)
      debugNode.onMouseMove = proc(n: Node, e: Event): bool =
        discard app.debugSidebar.handleMouse(e, n.bounds)
        true
      debugNode.onMouseWheel = proc(n: Node, e: Event): bool =
        return app.debugSidebar.handleMouse(e, n.bounds)
      debugNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
        if app.debugSidebar.hoverBtn.len > 0: curHand
        elif app.debugSidebar.hoverRow >= 0: curHand
        else: curDefault)
      root.addChild(debugNode)
    else:
      let explorerNode = newNode("fileExplorer")
      explorerNode.bounds = layout.sidebar
      explorerNode.zIndex = 2
      explorerNode.onMouseDown = proc(n: Node, e: Event): bool =
        app.focus = "files"
        return app.fileExplorer.handleMouse(e, n.bounds)
      explorerNode.onMouseMove = proc(n: Node, e: Event): bool =
        discard app.fileExplorer.handleMouse(e, n.bounds)
        true
      explorerNode.onMouseWheel = proc(n: Node, e: Event): bool =
        return app.fileExplorer.handleMouse(e, n.bounds)
      explorerNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
        if app.fileExplorer.hoveredNode != nil: curHand else: curDefault)
      root.addChild(explorerNode)

  # Right panel resize handle
  if app.aiPanelVisible:
    let rightResizeNode = newNode("rightPanelResize")
    rightResizeNode.bounds = rect(layout.rightPanel.x - 2, TopBarHeight, 4, max(0, layout.screen.h - TopBarHeight - StatusHeight))
    rightResizeNode.zIndex = 10
    rightResizeNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.aiPanelDragging = true
      app.aiPanelDragStartX = e.x
      false
    rightResizeNode.onMouseMove = proc(n: Node, e: Event): bool =
      true
    rightResizeNode.setCursorStyle(curSizeWE)
    root.addChild(rightResizeNode)

  # Right panel node
  if app.aiPanelVisible:
    let aiNode = newNode("aiPanel")
    aiNode.bounds = layout.rightPanel
    aiNode.zIndex = 2
    aiNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.focus = "aiPanel"
      discard app.aiPanel.handleMouse(e, n.bounds)
      false
    aiNode.onMouseMove = proc(n: Node, e: Event): bool =
      discard app.aiPanel.handleMouse(e, n.bounds)
      true
    aiNode.onMouseWheel = proc(n: Node, e: Event): bool =
      discard app.aiPanel.handleMouse(e, n.bounds)
      true
    aiNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
      if app.aiPanel.hoverNewChat or app.aiPanel.hoverStop or app.aiPanel.hoverModelMenu or
         app.aiPanel.hoverPlanMode or app.aiPanel.hoverVariants: curHand
      elif app.aiPanel.hoverInput: curIbeam
      else: curDefault)
    root.addChild(aiNode)

  # Terminal node
  if app.showTerminal:
    let termNode = newNode("terminal")
    termNode.bounds = rect(layout.term.x, layout.term.y + TerminalHeaderHeight,
                           layout.term.w, max(0, layout.term.h - TerminalHeaderHeight))
    termNode.zIndex = 3
    termNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.focus = "term"
      false
    termNode.onMouseMove = proc(n: Node, e: Event): bool =
      true
    termNode.setCursorStyle(curIbeam)
    root.addChild(termNode)

  # Status bar container (rendered as a whole; clickable sections are child nodes)
  let statusNode = newNode("statusBar")
  statusNode.bounds = layout.status
  statusNode.zIndex = 4
  statusNode.onMouseMove = proc(n: Node, e: Event): bool =
    app.statusBar.hoverRightIndex = app.rightSectionIndexAt(n.bounds, e.x, e.y)
    true
  root.addChild(statusNode)

  let lspBounds = app.lspSectionBounds(layout.status)
  if lspBounds.w > 0:
    let lspNode = newNode("lspSection")
    lspNode.bounds = lspBounds
    lspNode.zIndex = 5
    lspNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.showLSPServerMenu(lspNode.bounds)
      true
    lspNode.setCursorStyle(curHand)
    statusNode.addChild(lspNode)

  let branchBounds = app.branchSectionBounds(layout.status)
  if branchBounds.w > 0:
    let branchNode = newNode("branchSection")
    branchNode.bounds = branchBounds
    branchNode.zIndex = 5
    branchNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.showBranchMenu(branchNode.bounds)
      true
    branchNode.setCursorStyle(curHand)
    statusNode.addChild(branchNode)

  let diagBounds = app.diagSectionBounds(layout.status)
  if diagBounds.w > 0:
    let diagNode = newNode("diagSection")
    diagNode.bounds = diagBounds
    diagNode.zIndex = 5
    diagNode.onMouseDown = proc(n: Node, e: Event): bool =
      app.showTerminal = true
      app.bottomPanelTab = "problems"
      true
    diagNode.setCursorStyle(curHand)
    statusNode.addChild(diagNode)

  # Line-ending and encoding clickable sections
  let leIdx = app.statusBar.lineEndingIndex
  if leIdx >= 0 and leIdx < app.statusBar.rightSectionBounds.len:
    let leBounds = app.statusBar.rightSectionBounds[leIdx]
    if leBounds.w > 0:
      let leNode = newNode("lineEndingSection")
      leNode.bounds = leBounds
      leNode.zIndex = 5
      leNode.onMouseDown = proc(n: Node, e: Event): bool =
        app.contextMenu.clear()
        let anchor = n.bounds
        app.contextMenu.addItem("le_lf", "LF", proc() =
          if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and
             not app.buffers[app.currentBuffer].isImage:
            var text = app.buffers[app.currentBuffer].ed.fullText()
            text = text.replace("\r\n", "\n").replace("\r", "\n")
            app.buffers[app.currentBuffer].ed.setText(text)
            app.buffers[app.currentBuffer].ed.markChanged()
            app.updateStatus())
        app.contextMenu.addItem("le_crlf", "CRLF", proc() =
          if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and
             not app.buffers[app.currentBuffer].isImage:
            var text = app.buffers[app.currentBuffer].ed.fullText()
            text = text.replace("\r\n", "\n").replace("\r", "\n")
            text = text.replace("\n", "\r\n")
            app.buffers[app.currentBuffer].ed.setText(text)
            app.buffers[app.currentBuffer].ed.markChanged()
            app.updateStatus())
        app.contextMenu.addItem("le_cr", "CR", proc() =
          if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and
             not app.buffers[app.currentBuffer].isImage:
            var text = app.buffers[app.currentBuffer].ed.fullText()
            text = text.replace("\r\n", "\n").replace("\r", "\n")
            text = text.replace("\n", "\r")
            app.buffers[app.currentBuffer].ed.setText(text)
            app.buffers[app.currentBuffer].ed.markChanged()
            app.updateStatus())
        app.contextMenu.showAt(anchor.x, anchor.y - app.contextMenu.bounds.h, app.width, app.height)
        true
      leNode.setCursorStyle(curHand)
      statusNode.addChild(leNode)

  let encIdx = app.statusBar.encodingIndex
  if encIdx >= 0 and encIdx < app.statusBar.rightSectionBounds.len:
    let encBounds = app.statusBar.rightSectionBounds[encIdx]
    if encBounds.w > 0:
      let encNode = newNode("encodingSection")
      encNode.bounds = encBounds
      encNode.zIndex = 5
      encNode.onMouseDown = proc(n: Node, e: Event): bool =
        app.contextMenu.clear()
        let anchor = n.bounds
        app.contextMenu.addItem("enc_utf8", "UTF-8 (current)", proc() = discard)
        app.contextMenu.addItem("enc_latin1", "Re-open as Latin-1", proc() =
          if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
            let path = app.buffers[app.currentBuffer].path
            if path.len > 0 and fileExists(path):
              try:
                let raw = readFile(path)
                var converted = newStringOfCap(raw.len * 2)
                for c in raw:
                  let b = ord(c)
                  if b < 128:
                    converted.add(c)
                  else:
                    # Encode Latin-1 byte as UTF-8 two-byte sequence
                    converted.add(chr(0xC0 or (b shr 6)))
                    converted.add(chr(0x80 or (b and 0x3F)))
                app.buffers[app.currentBuffer].ed.setText(converted)
                discard app.notificationManager.info("Re-opened as Latin-1")
              except CatchableError as ex:
                discard app.notificationManager.error("Failed to re-open: " & ex.msg))
        app.contextMenu.showAt(anchor.x, anchor.y - app.contextMenu.bounds.h, app.width, app.height)
        true
      encNode.setCursorStyle(curHand)
      statusNode.addChild(encNode)

  # Tab bar node
  let tabNode = newNode("tabBar")
  tabNode.bounds = rect(TabBarStartX,
                        layout.topBar.y,
                        max(0, layout.topBar.w - TabBarStartX),
                        layout.topBar.h)
  tabNode.zIndex = 5
  tabNode.onMouseDown = proc(n: Node, e: Event): bool =
    if app.tabBar.handleMouse(point(e.x, e.y), true, e.button):
      app.focus = "tabs"
    else:
      app.focus = "editor"
    false
  tabNode.onMouseMove = proc(n: Node, e: Event): bool =
    app.tabBar.handleHover(point(e.x, e.y))
    true
  tabNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
    if app.tabBar.hoverCloseTabIndex >= 0: curHand else: curDefault)
  root.addChild(tabNode)

  # Title bar buttons node
  let titleNode = newNode("titleBarButtons")
  titleNode.bounds = rect(layout.topBar.x, layout.topBar.y,
                          TitleBarButtonWidth * TitleBarButtonCount, layout.topBar.h)
  titleNode.zIndex = 6
  titleNode.onMouseDown = proc(n: Node, e: Event): bool =
    if e.y < TopBarHeight and e.x < TitleBarButtonWidth * TitleBarButtonCount:
      let btnIdx = e.x div TitleBarButtonWidth
      case btnIdx:
        of 0:
          if app.sidebarVisible and not app.showGitPanel and not app.showSearchPanel and not app.showDebugPanel:
            app.sidebarVisible = false
          else:
            app.sidebarVisible = true
            app.showGitPanel = false
            app.showSearchPanel = false
            app.showDebugPanel = false
        of 1:
          app.showSearchPanel = not app.showSearchPanel
          app.showGitPanel = false
          app.showDebugPanel = false
          if app.showSearchPanel:
            app.sidebarVisible = true
            let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
            app.searchPanel.show(ed)
          else:
            let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
            app.searchPanel.hide(ed)
          if app.tooltip.visible: app.tooltip.hideTooltip()
        of 2:
          if app.sidebarVisible and app.showGitPanel:
            app.sidebarVisible = false
          else:
            app.sidebarVisible = true
            app.showGitPanel = true
            app.showSearchPanel = false
            app.showDebugPanel = false
            app.gitPanel.updateRepository()
        of 3:
          if app.sidebarVisible and app.showDebugPanel:
            app.sidebarVisible = false
          else:
            app.sidebarVisible = true
            app.showDebugPanel = true
            app.showGitPanel = false
            app.showSearchPanel = false
        else: discard
      return true
    false
  titleNode.onMouseMove = proc(n: Node, e: Event): bool =
    true
  titleNode.setCursorStyle(curHand)
  root.addChild(titleNode)

  # Terminal header drag/close node
  if app.showTerminal:
    let termHeaderNode = newNode("terminalHeader")
    termHeaderNode.bounds = layout.termHeader
    termHeaderNode.zIndex = 7
    termHeaderNode.onMouseDown = proc(n: Node, e: Event): bool =
      let hdr = layout.termHeader
      # Close button (rightmost ~30px)
      if e.x > hdr.x + hdr.w - 30:
        app.showTerminal = false
        if app.focus == "term": app.focus = "editor"
        return true
      # Tab clicks (left side: three tabs each ~90px wide)
      let tabW = 90
      if e.x < hdr.x + tabW:
        app.bottomPanelTab = "problems"
        return true
      elif e.x < hdr.x + tabW * 2:
        app.bottomPanelTab = "terminal"
        return true
      elif e.x < hdr.x + tabW * 3:
        app.bottomPanelTab = "debug"
        return true
      else:
        # Drag handle area
        app.terminalDragging = true
        app.terminalDragStartY = e.y
        app.terminalDragStartHeight = app.terminalHeight
        return true
    termHeaderNode.onMouseMove = proc(n: Node, e: Event): bool =
      true
    termHeaderNode.setCursorResolver(proc(n: Node, x, y: int): CursorKind =
      let hdr = layout.termHeader
      if x > hdr.x + hdr.w - 30: curHand
      elif x < hdr.x + 90 * 3: curHand
      else: curSizeNS)
    root.addChild(termHeaderNode)

    # Diagnostics panel mouse routing node
    if app.bottomPanelTab == "problems":
      let diagPanelNode = newNode("diagPanel")
      diagPanelNode.bounds = rect(layout.term.x, layout.term.y + TerminalHeaderHeight,
                                  layout.term.w, max(0, layout.term.h - TerminalHeaderHeight))
      diagPanelNode.zIndex = 8
      diagPanelNode.onMouseDown = proc(n: Node, e: Event): bool =
        return app.diagPanel.handleMouse(e, n.bounds)
      diagPanelNode.onMouseMove = proc(n: Node, e: Event): bool =
        discard app.diagPanel.handleMouse(e, n.bounds)
        true
      diagPanelNode.onMouseWheel = proc(n: Node, e: Event): bool =
        return app.diagPanel.handleMouse(e, n.bounds)
      diagPanelNode.setCursorStyle(curDefault)
      root.addChild(diagPanelNode)

    # Debug panel mouse routing node
    if app.bottomPanelTab == "debug":
      let debugPanelNode = newNode("debugPanel")
      debugPanelNode.bounds = rect(layout.term.x, layout.term.y + TerminalHeaderHeight,
                                   layout.term.w, max(0, layout.term.h - TerminalHeaderHeight))
      debugPanelNode.zIndex = 8
      debugPanelNode.onMouseDown = proc(n: Node, e: Event): bool =
        return app.debugPanel.handleMouse(e, n.bounds)
      debugPanelNode.onMouseMove = proc(n: Node, e: Event): bool =
        discard app.debugPanel.handleMouse(e, n.bounds)
        true
      debugPanelNode.onMouseWheel = proc(n: Node, e: Event): bool =
        return app.debugPanel.handleMouse(e, n.bounds)
      debugPanelNode.setCursorStyle(curDefault)
      root.addChild(debugPanelNode)

  addOverlays(root, app, layout)
  root

template buildNodeTree*(app, layout): Node =
  if app.screen == asWelcome:
    buildWelcomeRoot(app, layout)
  else:
    buildEditorRoot(app, layout)

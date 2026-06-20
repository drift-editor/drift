## Drift Editor - uirelays-based Application

import std/[os, osproc, strutils, json, options, monotimes, times, atomics]
import uirelays
import chronos
from pixie import readImage
import widgets/[synedit, terminal]
import ../ui/[tabs, command_palette, search_panel, notification, dialog, context_menu, file_explorer, git_panel, welcome_screen, theme, hover_tooltip, file_dialog, statusbar, icons, theme_loader, theme_selector, location_picker, node, diagnostics_panel, ai_panel, debug_panel, debug_sidebar]
import explorer_context
import ../services/[lsp_thread, lsp_client, ai_thread]
import ../services/dap_thread
import ../services/git as gitcmd
import ../core/types
import ../core/config as cfg
import ../core/recent_files
import ../editor/[marker_manager, color_highlight, git_diff, sticky_scroll]
import ../utils/text
import ../utils/file_watcher
import app_layout, app_cursors, event_router, app_tree, app_commands, commands
import ../ui/diff_view

proc isImageFile(path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii()
  ext in [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"]

type
  Buffer = object
    ed: SynEdit
    path: string
    isImage: bool
    image: Image
    imageWidth: int
    imageHeight: int
    readOnly: bool
    diffPath: string  ## For diff buffers: the file being diffed
    diffStaged: bool  ## For diff buffers: whether diffing against staged

  App* = ref object
    config: cfg.AppConfig
    width, height: int
    font: Font
    fm: FontMetrics
    uiFont: Font
    uiFm: FontMetrics
    termFont: Font
    termFm: FontMetrics
    statusFont: Font
    statusFm: FontMetrics
    tooltipFont: Font
    tooltipFm: FontMetrics
    focus: string
    screen*: AppScreen
    sidebarVisible: bool
    showGitPanel: bool
    showSearchPanel: bool
    showDebugPanel: bool
    showTerminal: bool
    terminalHeight: int
    terminalDragging: bool
    terminalDragStartY: int
    terminalDragStartHeight: int
    sidebarWidth: int
    sidebarDragging: bool
    sidebarDragStartX: int

    # Diagnostics panel
    diagPanel: DiagnosticsPanel
    debugPanel: DebugPanel
    debugSidebar: DebugSidebar
    bottomPanelTab: string  ## "terminal" or "problems" or "debug"

    # Widgets
    tabBar: TabBar
    fileExplorer: FileExplorer
    gitPanel: GitPanel
    statusBar: StatusBar
    term: Terminal
    commandPalette: CommandPalette
    searchPanel: SearchPanel
    themeSelector: ThemeSelector
    notificationManager: NotificationManager
    dialogManager: DialogManager
    contextMenu: ContextMenu
    lspMenu: ContextMenu
    branchMenu: ContextMenu
    inputDialog: InputDialog
    welcomeScreen: WelcomeScreen
    fileWatcher: FileWatcher
    tooltip: Tooltip
    locationPicker: LocationPicker

    # AI Panel
    aiPanelVisible: bool
    aiPanelWidth: int
    aiPanelDragging: bool
    aiPanelDragStartX: int
    aiPanel: AIPanel

    # AI Thread
    aiThread: AIThread

    # Diff View
    diffView: DiffView

    # Componentization
    rootNode*: Node
    commands*: CommandRegistry
    gi*: GlobalInput

    # Buffers
    buffers: seq[Buffer]
    currentBuffer: int
    recentFiles: seq[RecentFileEntry]

    # Marker management (parallel to buffers)
    bufferMarkers: seq[BufferMarkers]
    lastColorScanCacheIds: seq[int]
    lastDiagLines: seq[seq[int]]
    lastDiffLines: seq[seq[DiffLine]]
    bufferLines: seq[seq[string]]

    # LSP
    lspServer: string
    lspThread: LSPThread
    lspStarting: bool
    hoverMouseX, hoverMouseY: int

    # DAP
    dapThread: DAPThread
    dapStarting: bool
    debugSessionActive: bool
    debugStopped: bool
    debugStopThreadId: int
    breakpoints: seq[tuple[path: string; line: int; enabled: bool]]
    hoverPendingPos: int
    hoverPendingLine: int
    hoverPendingCol: int
    hoverPendingTick: int
    hoverRequestPos: int
    hoverRequestPath: string
    hoverRequestId: int
    hoverNextRequestId: int
    mouseX, mouseY: int
    lastCursor: CursorKind
    lastStatusText: string
    lastCurrentLine, lastCurrentCol: int

const
  TerminalHeight = 200

proc renderTitleBarButtons(app: App) =
  let bg = currentTheme.getColor(tcBackground)
  let surface = currentTheme.getColor(tcSurface)
  let accent = currentTheme.getColor(tcAccent)
  let buttonAreaW = TitleBarButtonWidth * TitleBarButtonCount
  fillRect(rect(0, 0, buttonAreaW, TopBarHeight), bg)
  for i in 0..<TitleBarButtonCount:
    let bx = i * TitleBarButtonWidth
    let bounds = rect(bx, 0, TitleBarButtonWidth, TopBarHeight)
    let active = case i
      of 0: app.sidebarVisible and not app.showGitPanel and not app.showSearchPanel and not app.showDebugPanel
      of 1: app.sidebarVisible and app.showSearchPanel
      of 2: app.sidebarVisible and app.showGitPanel
      of 3: app.sidebarVisible and app.showDebugPanel
      else: false
    let hovered = app.mouseY < TopBarHeight and app.mouseX >= bx and app.mouseX < bx + TitleBarButtonWidth
    if active:
      fillRect(bounds, surface)
      fillRect(rect(bx, 0, TitleBarButtonWidth, 2), accent)
    elif hovered:
      fillRect(bounds, color(255, 255, 255, 20))
    let iconId = case i
      of 0: iiExplorer
      of 1: iiSearch
      of 2: iiGitBranch
      of 3: iiBug
      else: iiNone
    drawIcon(iconId, bx + (TitleBarButtonWidth - 16) div 2, (TopBarHeight - 16) div 2)

proc setTheme*(app: App, name: string) =
  if name.len == 0:
    return
  setTheme(loadThemeByName(name))
  for i in 0 ..< app.buffers.len:
    app.buffers[i].ed.theme = driftSyneditTheme()
  app.term.ed.theme = driftSyneditTheme()
  if app.diffView != nil:
    app.diffView.leftEd.theme = driftSyneditTheme()
    app.diffView.rightEd.theme = driftSyneditTheme()
    app.diffView.applyDecorations()

proc applyTheme*(app: App, name: string) =
  if name.len == 0 or app.config.themeName == name:
    return
  app.setTheme(name)
  app.config.themeName = name
  saveConfig(app.config)

proc createApp*(config: cfg.AppConfig = cfg.defaultConfig()): App =
  var app = App(config: config, focus: "editor", screen: asWelcome, currentBuffer: -1, sidebarVisible: true, showGitPanel: false, showSearchPanel: false, showDebugPanel: false, terminalHeight: TerminalHeight, sidebarWidth: SidebarWidth, aiPanelVisible: false, aiPanelWidth: RightPanelWidth, hoverPendingPos: -1, hoverPendingTick: high(int), hoverRequestPos: -1, hoverRequestId: -1, aiPanel: newAIPanel(), debugSessionActive: false, debugStopped: false, debugStopThreadId: 0, breakpoints: @[])
  app.aiPanel.onSend = proc(text: string) =
    if app.aiThread == nil:
      app.aiThread = newAIThread()
    # Build prompt with editor context
    var promptText = text
    if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
      let b = app.buffers[app.currentBuffer]
      if not b.isImage and b.path.len > 0:
        let content = b.ed.fullText()
        if content.len > 0:
          promptText = "Current file: " & b.path & "\n```\n" & content & "\n```\n\n" & text
    app.aiThread.sendMessage(promptText)
    app.aiPanel.isStreaming = true
  app.aiPanel.onNewSession = proc() =
    if app.aiThread != nil:
      app.aiThread.newSession()
    app.aiPanel.clearChat()
  app.aiPanel.onStop = proc() =
    if app.aiThread != nil:
      app.aiThread.cancel()
  return app

proc clearHoverState(app: App; clearPending: bool = true) =
  app.hoverRequestId = -1
  app.hoverRequestPos = -1
  app.hoverRequestPath = ""
  if clearPending:
    app.hoverPendingPos = -1
    app.hoverPendingTick = high(int)

proc clearPendingHover(app: App) =
  app.hoverPendingPos = -1
  app.hoverPendingTick = high(int)

# Buffer management

proc langToString(lang: SourceLanguage): string =
  case lang
  of langNim: "NIM"
  of langCpp: "C++"
  of langCsharp: "C#"
  of langC: "C"
  of langJava: "JAVA"
  of langJs: "JS"
  of langXml: "XML"
  of langHtml: "HTML"
  of langConsole: "CONSOLE"
  of langPython: "PYTHON"
  of langRust: "RUST"
  of langMarkdown: "MARKDOWN"
  of langNone: "PLAIN"

proc detectLineEnding(text: string): string =
  if text.contains("\c\L"): "CRLF"
  else: "LF"

proc lspStatusString(app: App): string =
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    return "LSP: " & app.lspServer
  elif app.lspStarting:
    return "LSP: starting..."
  else:
    return "LSP: off"

proc dapStatusString(app: App): string =
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    if app.debugStopped:
      return "DBG: stopped"
    elif app.debugSessionActive:
      return "DBG: running"
    else:
      return "DBG: ready"
  elif app.dapStarting:
    return "DBG: starting..."
  else:
    return "DBG: off"

proc updateStatus(app: App) =
  var leftSections: seq[string]
  var rightSections: seq[string]
  var lspIdx = -1
  var dapIdx = -1
  var aiIdx = -1
  var currLine = 0
  var currCol = 0
  let branch = app.gitPanel.currentBranch
  let branchLabel = if branch.len > 0:
    branch & (if app.gitPanel.isDirty: " *" else: "")
  else: ""

  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    leftSections = if branchLabel.len > 0:
      @[branchLabel, "No file"]
    else:
      @["No file"]
    rightSections = @[app.lspStatusString(), app.dapStatusString(), "AI"]
    lspIdx = 0
    dapIdx = 1
    aiIdx = 2
  else:
    let b = app.buffers[app.currentBuffer]
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    if b.isImage:
      leftSections = @[name]
      rightSections = @[
        $b.imageWidth & " x " & $b.imageHeight,
        app.lspStatusString(),
        app.dapStatusString(),
        "AI"
      ]
      lspIdx = 1
      dapIdx = 2
      aiIdx = 3
    elif b.diffPath.len > 0:
      leftSections = @[name]
      rightSections = @["Diff", app.lspStatusString(), app.dapStatusString(), "AI"]
      lspIdx = 1
      dapIdx = 2
      aiIdx = 3
    else:
      let modified = if b.ed.changed: " *" else: ""
      let text = b.ed.fullText
      let lineEnding = detectLineEnding(text)
      let lang = langToString(b.ed.lang)
      currLine = b.ed.currentLine
      currCol = b.ed.currentCol
      leftSections = if branchLabel.len > 0:
        @[branchLabel, name & modified]
      else:
        @[name & modified]
      rightSections = @[
        "Ln " & $(currLine + 1) & ", Col " & $(currCol + 1),
        "UTF-8",
        lineEnding,
        lang,
        app.lspStatusString(),
        app.dapStatusString(),
        "AI"
      ]
      lspIdx = 4
      dapIdx = 5
      aiIdx = 6

  let statusText = leftSections.join(" | ") & " :: " & rightSections.join(" | ")
  if statusText != app.lastStatusText or currLine != app.lastCurrentLine or currCol != app.lastCurrentCol:
    app.statusBar.leftSections = leftSections
    app.statusBar.rightSections = rightSections
    app.statusBar.leftIcons = if leftSections.len > 0 and app.gitPanel.currentBranch.len > 0:
      @[iiGitBranch] & newSeq[IconId](leftSections.len - 1)
    else:
      newSeq[IconId](leftSections.len)
    app.statusBar.rightIcons = newSeq[IconId](rightSections.len)
    app.statusBar.rightIcons[^1] = iiSparkle
    app.statusBar.rightColors = @[]
    for _ in 0 ..< rightSections.len:
      app.statusBar.rightColors.add(color(0, 0, 0, 0))
    # Set active right index to AI section when panel is open
    app.statusBar.activeRightIndex = if app.aiPanelVisible: rightSections.len - 1 else: -1
    app.statusBar.lspIndex = lspIdx
    app.statusBar.dapIndex = dapIdx
    app.statusBar.aiIndex = aiIdx
    app.lastStatusText = statusText
    app.lastCurrentLine = currLine
    app.lastCurrentCol = currCol

  # Diagnostic summary section (always updated since counts change independently)
  let errCount = app.diagPanel.store.errorCount()
  let warnCount = app.diagPanel.store.warningCount()
  let baseLen = leftSections.len

  # Always show: [iiError] N  [iiWarning] N
  app.statusBar.leftSections.setLen(baseLen)
  app.statusBar.leftIcons.setLen(baseLen)
  app.statusBar.leftColors.setLen(baseLen)

  let errColor = if errCount > 0: currentTheme.getColor(tcError) else: currentTheme.getColor(tcText)
  let warnColor = if warnCount > 0: currentTheme.getColor(tcWarning) else: currentTheme.getColor(tcText)

  app.statusBar.leftSections.add($errCount)
  app.statusBar.leftIcons.add(iiError)
  app.statusBar.leftColors.add(errColor)

  app.statusBar.leftSections.add($warnCount)
  app.statusBar.leftIcons.add(iiWarning)
  app.statusBar.leftColors.add(warnColor)


proc rightSectionIndexAt(app: App, statusBounds: coords.Rect, px, py: int): int =
  ## Returns the index of the right status bar section at (px, py), or -1.
  if not statusBounds.contains(point(px, py)): return -1
  let font = app.statusFont
  var rightWidth = 0
  var sectionWidths: seq[int]
  for i, text in app.statusBar.rightSections:
    let ext = font.measureText(text)
    var sectionW = ext.w + SectionPadding * 2
    let icon = if i < app.statusBar.rightIcons.len: app.statusBar.rightIcons[i] else: iiNone
    if icon != iiNone:
      sectionW += 16 + 4
    sectionWidths.add(sectionW)
    rightWidth += sectionW
  var x = statusBounds.x + statusBounds.w - rightWidth + SectionPadding
  for i, w in sectionWidths:
    if px >= x and px < x + w:
      return i
    x += w
  return -1

proc sectionBoundsAtIndex(app: App, statusBounds: coords.Rect, idx: int): coords.Rect =
  ## Compute the bounds of the right status bar section at the given index.
  if idx < 0 or idx >= app.statusBar.rightSections.len:
    return rect(0, 0, 0, 0)
  let font = app.statusFont
  var rightWidth = 0
  for i, text in app.statusBar.rightSections:
    let ext = font.measureText(text)
    var sectionW = ext.w + SectionPadding * 2
    let icon = if i < app.statusBar.rightIcons.len: app.statusBar.rightIcons[i] else: iiNone
    if icon != iiNone:
      sectionW += 16 + 4
    rightWidth += sectionW
  var x = statusBounds.x + statusBounds.w - rightWidth + SectionPadding
  for i, text in app.statusBar.rightSections:
    let ext = font.measureText(text)
    var w = ext.w + SectionPadding * 2
    let icon = if i < app.statusBar.rightIcons.len: app.statusBar.rightIcons[i] else: iiNone
    if icon != iiNone:
      w += 16 + 4
    if i == idx:
      return rect(x, statusBounds.y, w, statusBounds.h)
    x += w

proc aiSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  sectionBoundsAtIndex(app, statusBounds, app.statusBar.aiIndex)

proc pathStartsWith(path, prefix: string): bool =
  ## Cross-platform path prefix check normalizing both separators.
  let normPath = path.replace('\\', '/')
  let normPrefix = prefix.replace('\\', '/')
  normPath.startsWith(normPrefix & "/")

proc lspSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  sectionBoundsAtIndex(app, statusBounds, app.statusBar.lspIndex)

proc branchSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  if app.statusBar.leftSections.len < 2: return rect(0, 0, 0, 0)
  let font = app.statusFont
  let ext = font.measureText(app.statusBar.leftSections[0])
  let iconW = 16 + 4  # icon + gap
  let w = iconW + ext.w + SectionPadding * 2
  return rect(statusBounds.x + SectionPadding, statusBounds.y, w, statusBounds.h)

proc diagSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  ## Returns the bounds covering both the error and warning status bar sections (last 2 left sections).
  if app.statusBar.leftSections.len < 2: return rect(0, 0, 0, 0)
  let font = app.statusFont
  var x = statusBounds.x + SectionPadding
  let diagStart = app.statusBar.leftSections.len - 2  # first of the two diag slots
  for i, text in app.statusBar.leftSections:
    let icon = if i < app.statusBar.leftIcons.len: app.statusBar.leftIcons[i] else: iiNone
    let iconW = if icon != iiNone: 16 + 4 else: 0
    let ext = font.measureText(text)
    let w = iconW + ext.w + SectionPadding * 2
    if i == diagStart:
      # measure from here to end of last section
      var totalW = w
      if i + 1 < app.statusBar.leftSections.len:
        let icon2 = if i+1 < app.statusBar.leftIcons.len: app.statusBar.leftIcons[i+1] else: iiNone
        let iconW2 = if icon2 != iiNone: 16 + 4 else: 0
        let ext2 = font.measureText(app.statusBar.leftSections[i+1])
        totalW += iconW2 + ext2.w + SectionPadding * 2
      return rect(x, statusBounds.y, totalW, statusBounds.h)
    x += w

type
  ChangeGroup* = object
    name*: string
    files*: seq[string]
    diff*: string

proc groupFilesByConcern*(files: seq[GitFileChange]): seq[ChangeGroup] =
  ## Group changed files by logical concern based on path/extension.
  var src, tests, config, docs, build, other: seq[string]
  for f in files:
    let path = f.path.toLowerAscii()
    if path.endsWith("_test.nim") or path.contains("/tests/") or path.startsWith("tests/"):
      tests.add(f.path)
    elif path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".cfg"):
      src.add(f.path)
    elif path.endsWith(".json") or path.endsWith(".yaml") or path.endsWith(".yml") or path.endsWith(".toml") or path == ".gitignore":
      config.add(f.path)
    elif path.endsWith(".md") or path.endsWith(".rst") or path.endsWith(".txt"):
      docs.add(f.path)
    elif path.endsWith(".nimble") or path.contains("makefile") or path.endsWith(".sh"):
      build.add(f.path)
    else:
      other.add(f.path)

  if src.len > 0: result.add(ChangeGroup(name: "Source Code", files: src))
  if tests.len > 0: result.add(ChangeGroup(name: "Tests", files: tests))
  if config.len > 0: result.add(ChangeGroup(name: "Configuration", files: config))
  if docs.len > 0: result.add(ChangeGroup(name: "Documentation", files: docs))
  if build.len > 0: result.add(ChangeGroup(name: "Build / Scripts", files: build))
  if other.len > 0: result.add(ChangeGroup(name: "Other", files: other))

proc collectGroupDiff(repoRoot: string; group: var ChangeGroup; staged, unstaged: seq[GitFileChange]) =
  ## Collect diff text for all files in a group.
  var diffText = ""
  for filePath in group.files:
    # Check if file is staged
    var isStaged = false
    for s in staged:
      if s.path == filePath:
        isStaged = true
        break
    # Check if file is unstaged (or untracked)
    var isUnstaged = false
    for u in unstaged:
      if u.path == filePath:
        isUnstaged = true
        break

    if isStaged:
      let d = gitcmd.getFileDiff(repoRoot, filePath, staged = true)
      if d.len > 0:
        diffText.add("### " & filePath & " (staged)\n```diff\n" & d & "\n```\n\n")
    if isUnstaged:
      let d = gitcmd.getFileDiff(repoRoot, filePath, staged = false)
      if d.len > 0:
        diffText.add("### " & filePath & " (unstaged)\n```diff\n" & d & "\n```\n\n")
      else:
        # Untracked file - show full content
        let content = gitcmd.getUntrackedFileContent(repoRoot, filePath)
        if content.len > 0:
          diffText.add("### " & filePath & " (new file)\n```\n" & content & "\n```\n\n")

  group.diff = diffText

proc reviewChanges*(app: App) =
  ## Lazy agentic review: send only file list + stats, let the agent explore files and diffs via tools.
  let repoRoot = if app.gitPanel.currentPath.len > 0: app.gitPanel.currentPath else: getCurrentDir()
  if not gitcmd.isGitRepository(repoRoot):
    discard app.notificationManager.warning("Not a git repository")
    return

  let allStatus = gitcmd.parseGitStatus(repoRoot)
  var stagedFiles, unstagedFiles: seq[GitFileChange]
  for f in allStatus:
    if f.stagedStatus != gfsUnmodified:
      stagedFiles.add(f)
    if f.workingStatus != gfsUnmodified:
      unstagedFiles.add(f)

  if stagedFiles.len == 0 and unstagedFiles.len == 0:
    discard app.notificationManager.info("No local changes to review")
    return

  # Build deduplicated file list
  var allFiles = stagedFiles
  for u in unstagedFiles:
    var found = false
    for a in allFiles:
      if a.path == u.path:
        found = true
        break
    if not found: allFiles.add(u)

  var fileList = ""
  for f in allFiles:
    var parts: seq[string]
    if f.stagedStatus != gfsUnmodified:
      parts.add("staged")
    if f.workingStatus != gfsUnmodified:
      if f.workingStatus == gfsUntracked:
        parts.add("new")
      else:
        parts.add("unstaged")
    fileList.add("- " & f.path & " (" & parts.join(", ") & ")\n")

  let branch = gitcmd.getCurrentBranch(repoRoot)

  var prompt = "You are conducting a code review of local git changes.\n\n"
  prompt.add("Repository: " & repoRoot & "\n")
  prompt.add("Branch: " & branch & "\n\n")
  prompt.add("Changed files:\n" & fileList & "\n")
  prompt.add("Use the following tools to explore files and diffs as needed:\n")
  prompt.add("- `fs/read_text_file` — read the full content of any file (pass absolute path as `\"path\"`)\n")
  prompt.add("- `git/get_file_diff` — get the diff for a specific file (pass absolute path as `\"path\"`)\n")
  prompt.add("- `git/get_diff` — get the full working tree diff (pass `\"repoRoot\": \"" & repoRoot & "\"`)\n\n")
  prompt.add("Please review thoroughly. Provide:\n")
  prompt.add("1. **Summary** — what changed at a high level\n")
  prompt.add("2. **Issues** — bugs, anti-patterns, or concerns (with line references)\n")
  prompt.add("3. **Suggestions** — specific improvements with reasoning\n")
  prompt.add("4. **Approval status** — Approve / Request changes / Needs discussion\n")

  discard app.notificationManager.info("Sending " & $allFiles.len & " file(s) for AI review...")

  app.aiPanelVisible = true
  if app.aiThread == nil:
    app.aiThread = newAIThread()
  app.aiThread.sendMessage(prompt)
  app.aiPanel.isStreaming = true
  if app.tooltip.visible: app.tooltip.hideTooltip()

proc showBranchMenu(app: App, bounds: coords.Rect) =
  app.branchMenu.items = @[]
  let branches = app.gitPanel.listBranches()
  let current = app.gitPanel.currentBranch
  if branches.len == 0:
    let item = newMenuItem("none", "No branches found", proc() = discard)
    item.isEnabled = false
    app.branchMenu.addItem(item)
  else:
    proc makeCheckoutProc(b: string): proc() =
      result = proc() =
        if app.gitPanel.checkoutBranch(b):
          app.gitPanel.updateRepository()
    for b in branches:
      if b == current:
        app.branchMenu.addItem(newCheckboxItem(b, b, true, makeCheckoutProc(b)))
      else:
        app.branchMenu.addItem(newMenuItem(b, b, makeCheckoutProc(b)))
  app.branchMenu.showAt(bounds.x, bounds.y)
  app.branchMenu.bounds.y -= app.branchMenu.bounds.h

proc lspExeFor(serverName: string): string =
  case serverName
  of "languageserver": "nimlangserver"
  else: serverName

proc restartLSP(app: App, serverName: string) =
  app.lspServer = serverName
  app.config.lspServer = serverName
  saveConfig(app.config)
  # Stop existing LSP
  if app.lspThread != nil:
    app.lspThread.shutdown()
    app.lspThread = nil
  app.lspStarting = false
  # Clear diagnostics — both editor decorations and the panel store
  for i in 0 ..< app.lastDiagLines.len:
    app.lastDiagLines[i] = @[]
    if i < app.bufferMarkers.len:
      app.bufferMarkers[i].setMarkers(msDiagnostic, @[])
      applyMarkers(app.buffers[i].ed, app.bufferMarkers[i])
  app.diagPanel.store = DiagnosticStore()
  # Restart if any Nim buffer is open
  var hasNim = false
  for b in app.buffers:
    if b.path.endsWith(".nim") or b.path.len == 0:
      hasNim = true
      break
  if hasNim:
    app.lspThread = newLSPThread(lspExeFor(app.lspServer), app.config.lspConfig)
    app.lspStarting = true

proc showLSPServerMenu(app: App, lspBounds: coords.Rect) =
  app.lspMenu.items = @[]
  let servers = @[("minlsp", "minlsp"), ("languageserver", "nimlangserver"), ("nimlsp", "nimlsp")]
  proc makeRestartProc(server: string): proc() =
    result = proc() = restartLSP(app, server)
  for (lbl, exe) in servers:
    let available = findExe(exe).len > 0
    let isCurrent = app.lspServer == lbl
    let label = lbl
    var item: MenuItem
    if isCurrent and available:
      item = newCheckboxItem(label, label, true, makeRestartProc(label))
    elif available:
      item = newMenuItem(label, label, makeRestartProc(label))
    else:
      item = newMenuItem(label, label & " (not found)", proc() = discard)
      item.isEnabled = false
    app.lspMenu.addItem(item)
  app.lspMenu.showAt(lspBounds.x, lspBounds.y)
  app.lspMenu.bounds.x = lspBounds.x + lspBounds.w - app.lspMenu.bounds.w
  app.lspMenu.bounds.y -= app.lspMenu.bounds.h

proc updateTitle(app: App) =
  if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
    let b = app.buffers[app.currentBuffer]
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    setWindowTitle(name & " - Drift")
  else:
    setWindowTitle("Drift")

proc showWelcome*(app: App) =
  app.screen = asWelcome
  app.welcomeScreen.show()

proc hideWelcome*(app: App) =
  app.screen = asWorkspace
  app.welcomeScreen.hide()

proc updateBreakpointMarkers(app: App; idx: int)
proc loadDiffContent(app: App; path: string; staged: bool)

proc switchBuffer(app: App, idx: int) =
  if idx >= 0 and idx < app.buffers.len:
    app.currentBuffer = idx
    app.updateStatus()
    app.updateTitle()
    app.updateBreakpointMarkers(idx)
    # Update tab bar active state
    discard app.tabBar.setActiveTab($idx)
    # Hide welcome screen when switching to a buffer
    if app.screen == asWelcome:
      app.hideWelcome()
    # If switching to a diff buffer, refresh its content
    let b = app.buffers[idx]
    if b.diffPath.len > 0:
      app.loadDiffContent(b.diffPath, b.diffStaged)

proc closeBuffer(app: App, idx: int) =
  if idx < 0 or idx >= app.buffers.len:
    return

  # Notify LSP that the document is closed (keeps diagnostics in panel
  # for the user to browse even after the file is closed).
  let closedPath = app.buffers[idx].path
  if closedPath.len > 0 and app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    app.lspThread.notifyDidClose(closedPath)
  
  # Note: uirelays backends do not implement freeImage (drawRelays.freeImage
  # is nil), so we skip it to avoid SIGSEGV. Images are small and released
  # on process exit anyway.
  app.buffers.delete(idx)
  app.bufferMarkers.delete(idx)
  app.lastColorScanCacheIds.delete(idx)
  app.lastDiagLines.delete(idx)
  app.lastDiffLines.delete(idx)
  app.bufferLines.delete(idx)
  if app.buffers.len == 0:
    app.currentBuffer = -1
  else:
    app.switchBuffer(min(idx, app.buffers.high))
  # Rebuild tabs
  app.tabBar.clearTabs()
  for i, b in app.buffers:
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    discard app.tabBar.addTab($i, name)
  if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
    discard app.tabBar.setActiveTab($app.currentBuffer)

proc loadDiffContent(app: App; path: string; staged: bool) =
  ## Fetch git versions and populate the shared diff view.
  let repoRoot = if app.gitPanel.currentPath.len > 0: app.gitPanel.currentPath else: getCurrentDir()
  let (oldOutput, oldExit) = gitcmd.execGitCommand(
    if staged: @["show", ":" & path] else: @["show", "HEAD:" & path],
    repoRoot)
  let oldText = if oldExit == 0: oldOutput else: ""
  let fullPath = repoRoot / path
  var newText = ""
  if fileExists(fullPath):
    try:
      newText = readFile(fullPath)
    except CatchableError:
      discard
  if app.diffView == nil:
    app.diffView = newDiffView(app.font, driftSyneditTheme())
    app.diffView.onClose = proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        if app.buffers[app.currentBuffer].diffPath.len > 0:
          app.closeBuffer(app.currentBuffer)
  app.diffView.oldPath = path
  app.diffView.newPath = path
  app.diffView.setText(oldText, newText)
  app.diffView.setLabels("Previous", "Current")

proc showDiffView*(app: App; path: string; staged: bool = false) =
  ## Open a split diff view as a new tab.
  let repoRoot = if app.gitPanel.currentPath.len > 0: app.gitPanel.currentPath else: getCurrentDir()
  if not gitcmd.isGitRepository(repoRoot):
    discard app.notificationManager.warning("Not a git repository")
    return
  # Reuse existing diff buffer for this file if present
  for i, b in app.buffers:
    if b.diffPath == path and b.diffStaged == staged:
      app.switchBuffer(i)
      return
  # Create a new diff buffer
  var ed = createSynEdit(app.font, driftSyneditTheme())
  app.buffers.add(Buffer(
    ed: ed, path: path, readOnly: true,
    diffPath: path, diffStaged: staged))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  let idx = app.buffers.high
  discard app.tabBar.addTab($idx, path.extractFilename)
  app.switchBuffer(idx)
  app.loadDiffContent(path, staged)
  if app.tooltip.visible: app.tooltip.hideTooltip()

proc hideDiffView*(app: App) =
  discard

proc addRecentFile(app: App, path: string) =
  app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = false)
  saveRecentFiles(app.recentFiles)
  app.welcomeScreen.updateRecentFiles(recentItems(app.recentFiles))

proc addRecentFolder*(app: App, path: string) =
  app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = true)
  saveRecentFiles(app.recentFiles)
  app.welcomeScreen.updateRecentFiles(recentItems(app.recentFiles))

proc offsetAtPos(text: string; line, col: int): int =
  var currLine = 0
  var currCol = 0
  var i = 0
  while i < text.len:
    if currLine == line and currCol == col:
      return i
    if text[i] == '\n':
      inc currLine
      currCol = 0
    else:
      inc currCol
    inc i
  return text.len

proc bufferPosToLineCol(text: string; pos: int): tuple[line, col: int] =
  if pos <= 0:
    return (0, 0)
  if pos >= text.len:
    result.line = countLines(text) - 1
    var lastNl = -1
    for i in 0 ..< text.len:
      if text[i] == '\n':
        lastNl = i
    result.col = text.len - lastNl - 1
    return
  result.line = countLines(text[0 ..< pos]) - 1
  var lastNl = -1
  for i in 0 ..< pos:
    if text[i] == '\n':
      lastNl = i
  result.col = pos - lastNl - 1

proc updateBreakpointMarkers(app: App; idx: int) =
  if idx < 0 or idx >= app.buffers.len or idx >= app.bufferMarkers.len:
    return
  let path = app.buffers[idx].path
  var bpMarkers: seq[tuple[a, b: int, color: screen.Color]] = @[]
  if path.len > 0:
    for bp in app.breakpoints:
      if bp.path == path and bp.enabled:
        let lineStart = offsetAtPos(app.buffers[idx].ed.fullText(), bp.line, 0)
        bpMarkers.add((lineStart, lineStart, screen.color(220, 90, 90, 255)))
  app.bufferMarkers[idx].setMarkers(msBreakpoint, bpMarkers)
  applyMarkers(app.buffers[idx].ed, app.bufferMarkers[idx])

proc applyLineDecorations(app: App; idx: int) =
  app.buffers[idx].ed.clearLineDecorations()
  for line in app.lastDiagLines[idx]:
    app.buffers[idx].ed.setLineDecoration(line, color(243, 139, 168))
  for dl in app.lastDiffLines[idx]:
    case dl.kind
    of 'A':
      app.buffers[idx].ed.setLineDecoration(dl.line, currentTheme.getColor(tcSuccess))
    of 'M':
      app.buffers[idx].ed.setLineDecoration(dl.line, currentTheme.getColor(tcWarning))
    else:
      discard

proc handleDiagnostics(app: App; msg: JsonNode) =
  if not msg.hasKey("params"): return
  let params = msg["params"]
  if not params.hasKey("uri") or not params.hasKey("diagnostics"): return
  let uri = params["uri"].getStr()
  let diagCount = if params["diagnostics"].kind == JArray: params["diagnostics"].len else: 0
  stderr.writeLine("[app] handleDiagnostics: uri=" & uri & " count=" & $diagCount)

  # Normalize URI for comparison (remove file:// prefix and decode)
  let normalizedUri = decodeFileUri(uri)

  # Find if this file is open in any buffer
  var targetIdx = -1
  for i, b in app.buffers:
    if b.path == normalizedUri:
      targetIdx = i
      stderr.writeLine("[app] handleDiagnostics: matched buffer " & $i & " path=" & b.path)
      break

  # Parse all diagnostic entries (always do this, even for closed files)
  var parsedEntries: seq[DiagnosticEntry] = @[]
  let diagnostics = params["diagnostics"]
  if diagnostics.kind == JArray:
    for diag in diagnostics:
      if not diag.hasKey("range"): continue
      let range = diag["range"]
      let startLine = range["start"]["line"].getInt()
      let startChar = range["start"]["character"].getInt()
      let severity = if diag.hasKey("severity"): diag["severity"].getInt() else: SeverityError
      let message  = if diag.hasKey("message"): diag["message"].getStr() else: ""
      let source   = if diag.hasKey("source"): diag["source"].getStr() else: ""
      parsedEntries.add(DiagnosticEntry(
        uri:      uri,
        severity: severity,
        message:  message,
        source:   source,
        line:     startLine,
        col:      startChar
      ))

  # Always update the diagnostics panel store so users can browse all project
  # diagnostics, even for files that aren't currently open.
  app.diagPanel.update(uri, parsedEntries)

  # Apply markers only for open buffers
  if targetIdx >= 0:
    let text = app.buffers[targetIdx].ed.fullText()
    # Precompute line-start offsets to avoid O(lines) scans per diagnostic
    var lineStarts = @[0]
    for i, ch in text:
      if ch == '\n':
        lineStarts.add(i + 1)
    proc offsetFast(ls: seq[int]; line, col, maxLen: int): int =
      if line >= 0 and line < ls.len: result = ls[line] + col
      elif line < 0: result = col
      else: result = ls[^1] + col
      if result < 0: result = 0
      if result > maxLen: result = maxLen

    var diagMarkers: seq[tuple[a, b: int, color: screen.Color]] = @[]
    var diagLines: seq[int] = @[]
    if diagnostics.kind == JArray:
      for diag in diagnostics:
        if not diag.hasKey("range"): continue
        let range = diag["range"]
        if not range.hasKey("start") or not range.hasKey("end"): continue
        let start = range["start"]
        let `end` = range["end"]
        if not start.hasKey("line") or not start.hasKey("character"): continue
        if not `end`.hasKey("line") or not `end`.hasKey("character"): continue
        let startLine = start["line"].getInt()
        let startChar = start["character"].getInt()
        let endLine = `end`["line"].getInt()
        let endChar = `end`["character"].getInt()
        let a = offsetFast(lineStarts, startLine, startChar, text.len)
        let b = max(a, offsetFast(lineStarts, endLine, endChar, text.len) - 1)
        if b < a:
          diagMarkers.add((a, a, color(243, 139, 168, 80)))
        else:
          diagMarkers.add((a, b, color(243, 139, 168, 80)))
        diagLines.add(startLine)

    app.lastDiagLines[targetIdx] = diagLines
    app.bufferMarkers[targetIdx].setMarkers(msDiagnostic, diagMarkers)
    applyMarkers(app.buffers[targetIdx].ed, app.bufferMarkers[targetIdx])
    applyLineDecorations(app, targetIdx)

proc isBinaryFile(path: string): bool =
  if not fileExists(path):
    return false
  try:
    let f = open(path, fmRead)
    defer: f.close()
    var buf: array[8192, char]
    let read = f.readChars(toOpenArray(buf, 0, buf.len - 1))
    for i in 0 ..< read:
      if buf[i] == '\0':
        return true
    # Limitation: only the first 8KB is scanned; null bytes beyond this
    # point will go undetected. For robust detection the whole file should
    # be scanned in chunks.
  except CatchableError:
    return true
  return false

proc openBuffer(app: App, path: string): int =
  for i, b in app.buffers:
    if b.path == path:
      app.switchBuffer(i)
      return i
  # Image files bypass binary check
  let isImg = path.len > 0 and isImageFile(path)
  if path.len > 0 and not isImg and isBinaryFile(path):
    return -1

  if isImg:
    let img = loadImage(path)
    if img.int == 0:
      discard app.notificationManager.error("Failed to load image: " & path.extractFilename)
      return -1
    # Get image dimensions via pixie
    var imgW, imgH: int
    try:
      let pixieImg = readImage(path)
      imgW = pixieImg.width
      imgH = pixieImg.height
    except CatchableError:
      imgW = 0
      imgH = 0
    var ed = createSynEdit(app.font, driftSyneditTheme())
    app.buffers.add(Buffer(
      ed: ed, path: path, isImage: true, image: img,
      imageWidth: imgW, imageHeight: imgH))
    app.bufferMarkers.add(initBufferMarkers())
    app.lastColorScanCacheIds.add(0)
    app.lastDiagLines.add(@[])
    app.lastDiffLines.add(@[])
    app.bufferLines.add(@[])
    result = app.buffers.high
    let name = path.extractFilename
    discard app.tabBar.addTab($result, name)
    app.switchBuffer(result)
    return result

  var ed = createSynEdit(app.font, driftSyneditTheme())
  ed.showLineNumbers = true
  ed.lang = fileExtToLanguage(path.splitFile.ext)
  if fileExists(path):
    try:
      ed.loadFromFile(path)
    except CatchableError as err:
      discard app.notificationManager.error("Failed to load " & path.extractFilename & ": " & err.msg)
  app.buffers.add(Buffer(ed: ed, path: path))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  result = app.buffers.high
  if path.len > 0:
    app.lastDiffLines[result] = getDiffLines(path)
  let name = if path.len > 0: path.extractFilename else: "untitled"
  discard app.tabBar.addTab($result, name)
  app.switchBuffer(result)

  # Start LSP for Nim files
  if path.endsWith(".nim"):
    if app.lspThread.isNil and not app.lspStarting:
      stderr.writeLine("[app] starting LSP thread: " & lspExeFor(app.lspServer))
      app.lspThread = newLSPThread(lspExeFor(app.lspServer), app.config.lspConfig)
      app.lspStarting = true
    elif app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
      app.lspThread.notifyDidOpen(path, ed.fullText())

proc newBuffer(app: App) =
  var ed = createSynEdit(app.font, driftSyneditTheme())
  ed.showLineNumbers = true
  ed.lang = langNim
  app.buffers.add(Buffer(ed: ed, path: "", isImage: false))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  let idx = app.buffers.high
  discard app.tabBar.addTab($idx, "untitled")
  app.switchBuffer(idx)

proc newFile*(app: App)
proc openFolder*(app: App, path: string)

proc saveCurrentBuffer(app: App): bool =
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    return false
  let idx = app.currentBuffer
  if app.buffers[idx].path.len == 0:
    return false
  if app.buffers[idx].isImage:
    discard app.notificationManager.info("Images are read-only")
    return false
  try:
    app.buffers[idx].ed.saveToFile(app.buffers[idx].path)
  except CatchableError as err:
    discard app.notificationManager.error("Failed to save " & app.buffers[idx].path.extractFilename & ": " & err.msg)
    return false
  discard app.notificationManager.success("Saved " & app.buffers[idx].path.extractFilename)
  app.lastDiffLines[idx] = getDiffLines(app.buffers[idx].path)
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.buffers[idx].path.endsWith(".nim"):
    let text = app.buffers[idx].ed.fullText()
    app.lspThread.notifyDidChange(app.buffers[idx].path, text)
  return true

proc saveAsDialog*(app: App) =
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    return
  let defaultName = if app.buffers[app.currentBuffer].path.len > 0:
                      app.buffers[app.currentBuffer].path.extractFilename
                    else: "untitled.nim"
  var ext = defaultName.splitFile.ext
  if ext.len > 0 and ext[0] == '.': ext = ext[1..^1]
  let di = DialogInfo(kind: dkSaveFile, title: "Save File", extension: ext)
  let res = show(di)
  if res.isNone: return
  let path = res.get()
  app.buffers[app.currentBuffer].path = path
  try:
    app.buffers[app.currentBuffer].ed.saveToFile(path)
  except CatchableError as err:
    discard app.notificationManager.error("Failed to save " & path.extractFilename & ": " & err.msg)
    return
  discard app.notificationManager.success("Saved " & path.extractFilename)
  app.lastDiffLines[app.currentBuffer] = getDiffLines(path)
  app.updateTitle()
  app.updateStatus()
  app.tabBar.clearTabs()
  for i, b in app.buffers:
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    discard app.tabBar.addTab($i, name)
  discard app.tabBar.setActiveTab($app.currentBuffer)
  # Notify LSP about the new file path
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and path.endsWith(".nim"):
    let text = app.buffers[app.currentBuffer].ed.fullText()
    app.lspThread.notifyDidOpen(path, text)

proc openFileDialog*(app: App): bool =
  let di = DialogInfo(kind: dkOpenFile, title: "Open File")
  let res = show(di)
  if res.isSome:
    let path = res.get()
    if fileExists(path):
      discard app.openBuffer(path)
      app.addRecentFile(path)
      return true
  false

proc openFolderDialog*(app: App): bool =
  let di = DialogInfo(kind: dkSelectFolder, title: "Open Folder")
  let res = show(di)
  if res.isSome:
    let path = res.get()
    if dirExists(path):
      app.fileExplorer.setRootPath(path)
      app.gitPanel.currentPath = path
      app.gitPanel.updateRepository()
      app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = true)
      saveRecentFiles(app.recentFiles)
      app.welcomeScreen.updateRecentFiles(recentItems(app.recentFiles))
      return true
  false

# Public API

proc init*(app: App) =
  let layout = createWindow(app.config.windowWidth, app.config.windowHeight)
  app.width = layout.width
  app.height = layout.height
  setWindowTitle(app.config.windowTitle)

  let resourceDir = currentSourcePath().parentDir / ".." / ".." / "resources"
  let codeFontPath = resourceDir / "FiraCode-Regular.ttf"
  let uiFontPath = resourceDir / "Roboto-Regular.ttf"
  let termFontPath = resourceDir / "CascadiaMono.ttf"

  app.font = openFont(codeFontPath, 14, app.fm)
  if app.font.int == 0:
    stderr.writeLine("Fatal: failed to load code font: " & codeFontPath)
    quit(1)

  app.uiFont = openFont(uiFontPath, 13, app.uiFm)
  if app.uiFont.int == 0:
    app.uiFont = app.font
    app.uiFm = app.fm

  app.termFont = openFont(termFontPath, 14, app.termFm)
  if app.termFont.int == 0:
    app.termFont = app.font
    app.termFm = app.fm

  app.statusFont = openFont(uiFontPath, 12, app.statusFm)
  if app.statusFont.int == 0:
    app.statusFont = app.uiFont
    app.statusFm = app.uiFm

  app.tooltipFont = openFont(codeFontPath, 12, app.tooltipFm)
  if app.tooltipFont.int == 0:
    app.tooltipFont = app.font
    app.tooltipFm = app.fm

  # Load theme from config
  setTheme(loadThemeByName(app.config.themeName))

  setIconScale(layout.scaleX)
  loadIcons()

  # Tab bar
  app.tabBar = newTabBar()
  app.tabBar.onTabChange = proc(id: string) =
    try:
      app.switchBuffer(parseInt(id))
    except ValueError:
      discard
  app.tabBar.onTabClose = proc(id: string) =
    try:
      app.closeBuffer(parseInt(id))
    except ValueError:
      discard

  # File explorer
  app.fileExplorer = newFileExplorer()
  app.fileExplorer.onFileOpen = proc(path: string) =
    discard app.openBuffer(path)

  # File watcher for auto-refresh
  app.fileWatcher = newFileWatcher()

  # Git panel
  app.gitPanel = newGitPanel()
  app.gitPanel.onReview = proc() = app.reviewChanges()
  app.gitPanel.onShowDiff = proc(path: string, staged: bool) = app.showDiffView(path, staged)

  # Diagnostics panel
  app.diagPanel = newDiagnosticsPanel()
  app.diagPanel.onNavigate = proc(uri: string; line, col: int) =
    let path = decodeFileUri(uri)
    let idx = app.openBuffer(path)
    if idx < 0:
      discard app.notificationManager.error("Cannot open file: " & path.extractFilename)
    else:
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.gotoLine(line, col)  ## col is 0-based from LSP

  # Debug panel
  app.debugPanel = newDebugPanel()
  app.debugPanel.onNavigate = proc(path: string; line, col: int) =
    if path.len == 0: return
    let idx = app.openBuffer(path)
    if idx >= 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
      app.buffers[app.currentBuffer].ed.gotoLine(line, col)

  # Debug sidebar
  app.debugSidebar = newDebugSidebar()
  app.debugSidebar.onStartDebug = proc() =
    app.commands.exec("debug.start")
  app.debugSidebar.onStopDebug = proc() =
    app.commands.exec("debug.stop")
  app.debugSidebar.onContinue = proc() =
    app.commands.exec("debug.start")
  app.debugSidebar.onStepOver = proc() =
    app.commands.exec("debug.stepOver")
  app.debugSidebar.onStepInto = proc() =
    app.commands.exec("debug.stepInto")
  app.debugSidebar.onStepOut = proc() =
    app.commands.exec("debug.stepOut")
  app.debugSidebar.onNavigate = proc(path: string; line, col: int) =
    if path.len == 0: return
    let idx = app.openBuffer(path)
    if idx >= 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
      app.buffers[app.currentBuffer].ed.gotoLine(line, col)

  # Status bar
  app.lspServer = if app.config.lspServer.len > 0: app.config.lspServer else: "minlsp"
  app.statusBar = newStatusBar()

  # Terminal
  app.term = createTerminal(app.termFont, driftSyneditTheme())
  app.term.ed.appendOutput("Drift Terminal - Press Enter to execute commands\L")
  app.term.ed.appendOutput("$ ")

  # Overlays
  app.commandPalette = newCommandPalette()
  app.themeSelector = newThemeSelector()
  app.gi = GlobalInput()
  app.commands = newCommandRegistry()
  app.searchPanel = newSearchPanel(app.uiFont, app.uiFm)
  app.searchPanel.onWorkspaceResultClick = proc(path: string; line, col: int) =
    if fileExists(path):
      discard app.openBuffer(path)
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        app.buffers[app.currentBuffer].ed.gotoLine(line, col)
  app.notificationManager = newNotificationManager(rect(0, 0, app.width, app.height), app.uiFont)
  app.dialogManager = newDialogManager()
  app.contextMenu = newContextMenu(app.uiFont)
  app.lspMenu = newContextMenu(app.uiFont)
  app.branchMenu = newContextMenu(app.uiFont)
  app.inputDialog = newInputDialog("", "", app.uiFont)

  # Welcome screen
  app.welcomeScreen = newWelcomeScreen()
  app.welcomeScreen.onNewFile = proc() =
    app.newBuffer()
    app.hideWelcome()
  app.welcomeScreen.onOpenFile = proc() =
    if app.openFileDialog():
      app.hideWelcome()
  app.welcomeScreen.onOpenFolder = proc() =
    if app.openFolderDialog():
      app.hideWelcome()
  app.welcomeScreen.onOpenRecent = proc(path: string) =
    var isFolder = false
    for f in app.recentFiles:
      if f.path == path:
        isFolder = f.isFolder
        break
    if isFolder:
      if dirExists(path):
        app.openFolder(path)
        app.addRecentFolder(path)
        app.hideWelcome()
    else:
      if startAccessingRecentFile(app.recentFiles, path):
        discard app.openBuffer(path)
        app.addRecentFile(path)
        app.hideWelcome()
      else:
        app.recentFiles = loadRecentFiles()
        app.welcomeScreen.updateRecentFiles(recentItems(app.recentFiles))

  # Load persisted recent files
  app.recentFiles = loadRecentFiles()
  app.welcomeScreen.updateRecentFiles(recentItems(app.recentFiles))

  # Tooltip
  app.tooltip = newTooltip()

  # Location picker (goto-definition with multiple results)
  app.locationPicker = newLocationPicker()
  app.locationPicker.onSelect = proc(loc: Location) =
    let path = decodeFileUri(loc.uri)
    if fileExists(path):
      discard app.openBuffer(path)
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        let line = loc.range.start.line
        let col = loc.range.start.character
        app.buffers[app.currentBuffer].ed.gotoLine(line, col)

  # Command palette
  app.commandPalette.clearCommands()
  app.commandPalette.registerCommand("file.new", "New File", "Create a new file", ccFile, "Ctrl+N",
    proc() = app.newFile())
  app.commandPalette.registerCommand("file.open", "Open File", "Open an existing file", ccFile, "Ctrl+O",
    proc() = discard app.openFileDialog())
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
        app.inputDialog.show())
  app.commandPalette.registerCommand("palette.show", "Command Palette", "Show command palette", ccView, "Ctrl+Shift+P",
    proc() =
      app.commandPalette.switchToCommandMode()
      app.commandPalette.show())
  # Theme selector
  app.themeSelector.onPreview = proc(name: string) =
    app.setTheme(name)
  app.themeSelector.onApply = proc(name: string) =
    app.applyTheme(name)
  app.themeSelector.onCancel = proc() =
    app.setTheme(app.config.themeName)
  app.commandPalette.registerCommand("theme.selector", "Color Theme", "Open theme selector", ccView, "Ctrl+Shift+T",
    proc() =
      app.themeSelector.show(app.config.themeName))

  # Debug commands
  app.commandPalette.registerCommand("debug.start", "Start Debugging", "Start a debug session", ccDebug, "F5",
    proc() =
      if app.debugSessionActive:
        if app.debugStopped and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
          app.debugStopped = false
          app.debugPanel.status = "Running"
          app.dapThread.requestContinue(app.debugStopThreadId)
        return
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        discard app.notificationManager.error("No file open to debug")
        return
      let b = app.buffers[app.currentBuffer]
      if b.path.len == 0:
        discard app.notificationManager.error("Save the file before debugging")
        return
      let exePath = b.path.changeFileExt("")
      if not fileExists(exePath):
        discard app.notificationManager.info("Building " & b.path.extractFilename & "...")
        let buildRes = execCmdEx("nim c --debugger:native \"" & b.path & "\"")
        if buildRes.exitCode != 0:
          discard app.notificationManager.error("Build failed")
          app.debugPanel.addOutput(buildRes.output)
          app.showTerminal = true
          app.bottomPanelTab = "debug"
          return
      app.dapThread = newDAPThread(app.config.dapServer)
      app.dapStarting = true
      app.debugSessionActive = true
      app.debugStopped = false
      app.debugPanel.status = "Starting"
      app.debugPanel.clear()
      app.showTerminal = true
      app.bottomPanelTab = "debug"
      discard app.notificationManager.info("Debug session started"))

  app.commandPalette.registerCommand("debug.stop", "Stop Debugging", "Stop the current debug session", ccDebug, "Shift+F5",
    proc() =
      if app.dapThread != nil:
        app.dapThread.requestDisconnect()
        app.dapThread.shutdown()
        app.dapThread = nil
      app.dapStarting = false
      app.debugSessionActive = false
      app.debugStopped = false
      app.debugStopThreadId = 0
      app.debugPanel.status = "Not started"
      discard app.notificationManager.info("Debug session stopped"))

  app.commandPalette.registerCommand("debug.stepOver", "Step Over", "Step over the current line", ccDebug, "F10",
    proc() =
      if app.debugStopped and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
        app.debugStopped = false
        app.debugPanel.status = "Running"
        app.dapThread.requestNext(app.debugStopThreadId))

  app.commandPalette.registerCommand("debug.stepInto", "Step Into", "Step into the current function", ccDebug, "F11",
    proc() =
      if app.debugStopped and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
        app.debugStopped = false
        app.debugPanel.status = "Running"
        app.dapThread.requestStepIn(app.debugStopThreadId))

  app.commandPalette.registerCommand("debug.stepOut", "Step Out", "Step out of the current function", ccDebug, "Shift+F11",
    proc() =
      if app.debugStopped and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
        app.debugStopped = false
        app.debugPanel.status = "Running"
        app.dapThread.requestStepOut(app.debugStopThreadId))

  app.commandPalette.registerCommand("debug.toggleBreakpoint", "Toggle Breakpoint", "Toggle breakpoint on current line", ccDebug, "F9",
    proc() =
      if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
        return
      let b = app.buffers[app.currentBuffer]
      if b.path.len == 0: return
      let line = b.ed.currentLine
      var foundIdx = -1
      for i, bp in app.breakpoints:
        if bp.path == b.path and bp.line == line:
          foundIdx = i
          break
      if foundIdx >= 0:
        app.breakpoints.del(foundIdx)
      else:
        app.breakpoints.add((path: b.path, line: line, enabled: true))
      app.updateBreakpointMarkers(app.currentBuffer)
      # Update breakpoints in running session
      if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
        var lines: seq[int] = @[]
        for bp in app.breakpoints:
          if bp.path == b.path and bp.enabled:
            lines.add(bp.line)
        app.dapThread.requestSetBreakpoints(b.path, lines))

  app.commandPalette.registerCommand("view.toggleDebug", "Toggle Debug Panel", "Show the Debug panel in the bottom panel", ccView, "Ctrl+Shift+D",
    proc() =
      app.showTerminal = true
      app.bottomPanelTab = "debug")

  app.commandPalette.onFileSelect = proc(path: string) =
    discard app.openBuffer(path)

proc openFile*(app: App, path: string): bool =
  if not fileExists(path):
    return false
  discard app.openBuffer(path)
  app.addRecentFile(path)
  return true

proc openFolder*(app: App, path: string) =
  if dirExists(path):
    app.fileExplorer.setRootPath(path)
    app.gitPanel.currentPath = path
    app.gitPanel.updateRepository()
    app.searchPanel.workspaceRoot = path
    app.fileWatcher.addDir(path)

proc buildQuickOpenFiles(app: App): seq[FileItem] =
  var seen: seq[string] = @[]
  var items: seq[FileItem] = @[]
  proc addItem(path: string) =
    if path.len == 0: return
    for s in seen:
      if s == path: return
    seen.add(path)
    items.add(FileItem(name: path.extractFilename, path: path))

  # 1. Open buffers
  for b in app.buffers:
    addItem(b.path)

  # 2. Recent files (skip folders — quick open is for files only)
  for f in app.recentFiles:
    if not f.isFolder:
      addItem(f.path)

  # 3. Git repo files (if in a git repo)
  let cwd = getCurrentDir()
  let gitLs = execCmdEx("git ls-files", workingDir = cwd)
  if gitLs.exitCode == 0:
    for line in splitLines(gitLs.output):
      if line.len > 0:
        addItem(cwd / line)

  return items

proc newFile*(app: App) =
  app.newBuffer()

proc heartbeat() {.async.} =
  while true:
    await sleepAsync(chronos.timer.milliseconds(16))

proc showLocationPicker*(app: App, locations: seq[Location]) =
  if locations.len == 0:
    return
  if locations.len == 1:
    if app.locationPicker.onSelect != nil:
      app.locationPicker.onSelect(locations[0])
    return

  var items: seq[LocationItem] = @[]
  for loc in locations:
    let path = decodeFileUri(loc.uri)
    let display = path.extractFilename & " :" & $(loc.range.start.line + 1) & ":" & $(loc.range.start.character + 1)
    items.add(LocationItem(display: display, loc: loc))

  app.locationPicker.show(items, app.mouseX, app.mouseY)

proc run*(app: App) =
  # Command system init (done here so template can see all app procs)
  initCommands(app)

  var running = true
  app.welcomeScreen.show()
  asyncSpawn heartbeat()

  var lastFrameTime = getMonoTime()
  while running:
    poll()
    let now = getMonoTime()
    let delta = (now - lastFrameTime).inMilliSeconds.int
    lastFrameTime = now
    app.notificationManager.updateViewport(rect(0, 0, app.width, app.height))

    let layout = computeLayout(app.width, app.height, app.sidebarVisible, app.showTerminal, app.terminalHeight, app.sidebarWidth, app.aiPanelVisible, app.aiPanelWidth)
    let sidebarBounds = layout.sidebar
    let editorBounds = layout.editor
    let termBounds = layout.term
    let statusBounds = layout.status
    let termHeaderBounds = layout.termHeader
    let termContentBounds = rect(termBounds.x, termBounds.y + TerminalHeaderHeight, termBounds.w, max(0, termBounds.h - TerminalHeaderHeight))

    # Background
    fillRect(rect(0, 0, app.width, app.height), currentTheme.getColor(tcBackground))

    var e = default Event
    discard waitEvent(e, 500, {WantTextInput})

    # Event handling: componentized tree + command system
    app.gi.lastEvent = e
    app.gi.consumed = false
    if e.kind == MouseDownEvent or e.kind == MouseMoveEvent or e.kind == MouseUpEvent:
      app.mouseX = e.x
      app.mouseY = e.y
      app.gi.mouseX = e.x
      app.gi.mouseY = e.y

    # 1. Modals always win first
    if app.inputDialog.isVisible and app.inputDialog.handleInput(e):
      discard app.gi.consume()
    elif app.dialogManager.isModalActive() and app.dialogManager.handleInput(e):
      discard app.gi.consume()
    elif app.themeSelector.isVisible and app.themeSelector.handleInput(e):
      discard app.gi.consume()
    elif app.locationPicker.isVisible and app.locationPicker.handleInput(e):
      discard app.gi.consume()
    elif app.contextMenu.isVisible and app.contextMenu.handleInput(e):
      discard app.gi.consume()
    elif app.lspMenu.isVisible and app.lspMenu.handleInput(e):
      discard app.gi.consume()
    elif app.branchMenu.isVisible and app.branchMenu.handleInput(e):
      discard app.gi.consume()

    # 2. Welcome screen mouse handling (when visible)
    if app.screen == asWelcome and e.kind in {MouseDownEvent, MouseMoveEvent}:
      if app.welcomeScreen.handleMouse(e, app.width, app.height):
        discard app.gi.consume()

    # 3. Build node tree and route mouse through it
    app.rootNode = buildNodeTree(app, layout)
    if e.kind in {MouseDownEvent, MouseMoveEvent, MouseUpEvent, MouseWheelEvent}:
      let mk = case e.kind
        of MouseDownEvent: mkDown
        of MouseMoveEvent: mkMove
        of MouseUpEvent: mkUp
        of MouseWheelEvent: mkWheel
        else: mkDown
      if app.gi.dispatchMouse(app.rootNode, mk):
        discard

    # Diff view mouse handling (when active, after node tree dispatch)
    let isDiffBuffer = app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and
                       app.buffers[app.currentBuffer].diffPath.len > 0
    if isDiffBuffer and app.diffView != nil and not app.gi.isConsumed and
       e.kind in {MouseDownEvent, MouseMoveEvent, MouseUpEvent, MouseWheelEvent} and
       editorBounds.contains(point(e.x, e.y)):
      if app.diffView.handleMouse(e):
        app.focus = "editor"
        discard app.gi.consume()

    # 3. Handle window-level events
    if not app.gi.isConsumed:
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
        discard app.gi.consume()
      of WindowResizeEvent:
        app.width = e.x
        app.height = e.y
        discard app.gi.consume()
      else:
        discard

    # 4. Keyboard routing: overlays -> focus component -> global commands -> Esc
    # Editor and Terminal handle keys in their draw() during render phase;
    # they receive the raw event as long as nothing above consumes it.
    if not app.gi.isConsumed and e.kind == KeyDownEvent:
      # Overlays always win first
      if app.themeSelector.isVisible and app.themeSelector.handleInput(e):
        discard app.gi.consume()
      elif app.commandPalette.isVisible and app.commandPalette.handleInput(e):
        discard app.gi.consume()
      # Focus-driven sidebar widgets (only when they have focus)
      elif app.focus == "files" and app.sidebarVisible and not app.showGitPanel and not app.showSearchPanel and not app.showDebugPanel:
        if app.fileExplorer.handleInput(e, sidebarBounds):
          discard app.gi.consume()
      elif app.focus == "git" and app.sidebarVisible and app.showGitPanel:
        if app.gitPanel.handleInput(e):
          discard app.gi.consume()
      elif app.focus == "search" and app.sidebarVisible and app.showSearchPanel:
        let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
        if app.searchPanel.handleInput(ed, e):
          discard app.gi.consume()
      elif app.focus == "debug" and app.sidebarVisible and app.showDebugPanel:
        if app.debugSidebar.handleInput(e):
          discard app.gi.consume()
      elif app.focus == "aiPanel" and app.aiPanelVisible:
        if app.aiPanel.handleKey(e):
          discard app.gi.consume()
      # Global commands (Ctrl+T, Ctrl+F, etc.)
      elif app.commands.dispatch(e):
        discard app.gi.consume()
      # Esc closes visible overlays/panels
      elif e.key == KeyEsc:
        if app.themeSelector.isVisible:
          app.themeSelector.cancel()
          discard app.gi.consume()
        elif app.locationPicker.isVisible:
          app.locationPicker.cancel()
          discard app.gi.consume()
        elif app.searchPanel.isVisible:
          let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
          app.searchPanel.hide(ed)
          discard app.gi.consume()
        elif app.commandPalette.isVisible:
          app.commandPalette.hide()
          discard app.gi.consume()
        elif app.aiPanelVisible:
          app.aiPanelVisible = false
          if app.focus == "aiPanel":
            app.focus = "editor"
          discard app.gi.consume()
        elif app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and
             app.buffers[app.currentBuffer].diffPath.len > 0:
          app.closeBuffer(app.currentBuffer)
          app.focus = "editor"
          discard app.gi.consume()
        if app.tooltip.visible:
          app.tooltip.hideTooltip()

    # 5. Text input passthrough for overlays and focus sidebar widgets
    if not app.gi.isConsumed and e.kind == TextInputEvent:
      if app.commandPalette.isVisible:
        if app.commandPalette.handleInput(e):
          discard app.gi.consume()
      elif app.focus == "git" and app.showGitPanel:
        if app.gitPanel.handleTextInput(e):
          discard app.gi.consume()
      elif app.focus == "search" and app.showSearchPanel:
        let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
        if app.searchPanel.handleInput(ed, e):
          discard app.gi.consume()
      elif app.focus == "debug" and app.showDebugPanel:
        if app.debugSidebar.handleInput(e):
          discard app.gi.consume()
      elif app.focus == "aiPanel" and app.aiPanelVisible:
        if app.aiPanel.handleTextInput(e):
          discard app.gi.consume()

    # 6. Global mouse side-effects (tooltip hide, terminal drag, hover cancel)
    if e.kind == MouseDownEvent:
      if app.tooltip.visible:
        app.tooltip.hideTooltip()
      if app.lspThread != nil: app.lspThread.cancelHover()
      app.clearHoverState()
      # Right-click context menu
      if e.button == RightButton:
        let termH = if app.showTerminal: app.terminalHeight else: 0
        let inExplorer = app.sidebarVisible and not app.showSearchPanel and not app.showGitPanel and not app.showDebugPanel and
                         e.x < editorBounds.x and e.y >= TopBarHeight and e.y < app.height - StatusHeight - termH
        if inExplorer:
          let node = app.fileExplorer.nodeAt(e.x, e.y, sidebarBounds)
          var callbacks = ExplorerMenuCallbacks()
          callbacks.onOpenFile = proc(path: string) =
            if fileExists(path): discard app.openBuffer(path)
          callbacks.onReveal = proc(path: string) =
            try:
              when defined(macosx):
                discard startProcess("/usr/bin/open", args = ["-R", path], options = {poUsePath})
              else:
                discard startProcess("/usr/bin/open", args = [path], options = {poUsePath})
            except CatchableError: discard
          callbacks.onCopyPath = proc(path: string) = putClipboardText(path)
          callbacks.onCopyRelativePath = proc(path: string) =
            putClipboardText(relativePath(path, app.fileExplorer.rootPath))
          callbacks.onNewFile = proc(dir: string) =
            app.inputDialog.title = "New File"
            app.inputDialog.prompt = "Enter file name:"
            app.inputDialog.text = ""
            app.inputDialog.centerOnScreen(app.width, app.height)
            app.inputDialog.onResult = proc(confirmed: bool, text: string) =
              if confirmed and text.len > 0:
                let newPath = dir / text
                try:
                  writeFile(newPath, "")
                  app.fileExplorer.refresh()
                  discard app.openBuffer(newPath)
                except CatchableError as err:
                  discard app.notificationManager.error("Failed to create file: " & err.msg)
            app.inputDialog.show()
          callbacks.onNewFolder = proc(dir: string) =
            app.inputDialog.title = "New Folder"
            app.inputDialog.prompt = "Enter folder name:"
            app.inputDialog.text = ""
            app.inputDialog.centerOnScreen(app.width, app.height)
            app.inputDialog.onResult = proc(confirmed: bool, text: string) =
              if confirmed and text.len > 0:
                let newPath = dir / text
                try:
                  createDir(newPath)
                  app.fileExplorer.refresh()
                except CatchableError as err:
                  discard app.notificationManager.error("Failed to create folder: " & err.msg)
            app.inputDialog.show()
          callbacks.onRefresh = proc() = app.fileExplorer.refresh()
          callbacks.onCollapseAll = proc() = app.fileExplorer.collapseAll()
          callbacks.onPaste = proc(dir: string) =
            let clip = getClipboardText()
            if clip.len > 0 and fileExists(clip):
              let dest = dir / clip.extractFilename
              try:
                copyFile(clip, dest)
                app.fileExplorer.refresh()
              except CatchableError as err:
                discard app.notificationManager.error("Failed to paste: " & err.msg)
          callbacks.onRenameFile = proc(path: string) =
            app.inputDialog.title = "Rename File"
            app.inputDialog.prompt = "Enter new name:"
            app.inputDialog.text = path.extractFilename
            app.inputDialog.centerOnScreen(app.width, app.height)
            app.inputDialog.onResult = proc(confirmed: bool, text: string) =
              if confirmed and text.len > 0 and text != path.extractFilename:
                let newPath = path.parentDir / text
                try:
                  moveFile(path, newPath)
                  for i, b in app.buffers:
                    if b.path == path:
                      app.buffers[i].path = newPath
                      app.tabBar.clearTabs()
                      for j, buf in app.buffers:
                        let name = if buf.path.len > 0: buf.path.extractFilename else: "untitled"
                        discard app.tabBar.addTab($(j), name)
                      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
                        discard app.tabBar.setActiveTab($app.currentBuffer)
                      break
                  app.fileExplorer.refresh()
                except CatchableError as err:
                  discard app.notificationManager.error("Failed to rename: " & err.msg)
            app.inputDialog.show()
          callbacks.onRenameFolder = proc(path: string) =
            app.inputDialog.title = "Rename Folder"
            app.inputDialog.prompt = "Enter new name:"
            app.inputDialog.text = path.extractFilename
            app.inputDialog.centerOnScreen(app.width, app.height)
            app.inputDialog.onResult = proc(confirmed: bool, text: string) =
              if confirmed and text.len > 0 and text != path.extractFilename:
                let newPath = path.parentDir / text
                try:
                  moveDir(path, newPath)
                  for i, b in app.buffers:
                    if pathStartsWith(b.path, path):
                      app.buffers[i].path = newPath / b.path.replace('\\', '/').relativePath(path.replace('\\', '/'))
                  app.fileExplorer.refresh()
                except CatchableError as err:
                  discard app.notificationManager.error("Failed to rename: " & err.msg)
            app.inputDialog.show()
          callbacks.onDeleteFile = proc(path: string) =
            let dlg = newOkCancelDialog("Delete File", "Are you sure you want to delete " & path.extractFilename & "?", app.uiFont, proc(res: DialogResult) =
              if res == drOk:
                try:
                  removeFile(path)
                  for i in countdown(app.buffers.high, 0):
                    if app.buffers[i].path == path:
                      app.closeBuffer(i)
                  app.fileExplorer.refresh()
                except CatchableError as err:
                  discard app.notificationManager.error("Failed to delete: " & err.msg)
            )
            dlg.centerOnScreen(app.width, app.height)
            app.dialogManager.show(dlg)
          callbacks.onDeleteFolder = proc(path: string) =
            let dlg = newOkCancelDialog("Delete Folder", "Are you sure you want to delete " & path.extractFilename & "?", app.uiFont, proc(res: DialogResult) =
              if res == drOk:
                try:
                  removeDir(path)
                  for i in countdown(app.buffers.high, 0):
                    if pathStartsWith(app.buffers[i].path, path):
                      app.closeBuffer(i)
                  app.fileExplorer.refresh()
                except CatchableError as err:
                  discard app.notificationManager.error("Failed to delete: " & err.msg)
            )
            dlg.centerOnScreen(app.width, app.height)
            app.dialogManager.show(dlg)
          buildExplorerContextMenu(app.contextMenu, node, app.fileExplorer.rootPath, app.width, app.height, app.uiFont, callbacks)
          app.contextMenu.showAt(e.x, e.y, app.width, app.height)
          discard app.gi.consume()
        elif app.sidebarVisible and app.showGitPanel and sidebarBounds.contains(point(e.x, e.y)):
          let (filePath, isStaged) = app.gitPanel.fileAt(e.x, e.y, sidebarBounds)
          if filePath.len > 0:
            app.contextMenu.clear()
            let fullPath = app.gitPanel.currentPath / filePath
            app.contextMenu.addItem("open", "Open File", proc() =
              if fileExists(fullPath): discard app.openBuffer(fullPath))
            app.contextMenu.addSeparator()
            if isStaged:
              app.contextMenu.addItem("unstage", "Unstage", proc() =
                discard app.gitPanel.unstageFile(filePath))
            else:
              app.contextMenu.addItem("stage", "Stage", proc() =
                discard app.gitPanel.stageFile(filePath))
            app.contextMenu.addItem("discard", "Discard Changes", proc() =
              discard app.gitPanel.discardChanges(filePath))
            app.contextMenu.addSeparator()
            app.contextMenu.addItem("ignore", "Add to .gitignore", proc() =
              discard app.gitPanel.addToGitignore(filePath))
            app.contextMenu.showAt(e.x, e.y)
            discard app.gi.consume()
        elif app.aiPanelVisible and layout.rightPanel.contains(point(e.x, e.y)):
          let messagesY = layout.rightPanel.y + 32  # HeaderHeight
          let inputY = layout.rightPanel.y + layout.rightPanel.h - 72  # InputHeight
          if e.y >= messagesY and e.y < inputY:
            app.contextMenu.clear()
            app.contextMenu.addItem("clear", "Clear Conversation", proc() =
              app.aiPanel.clearChat())
            app.contextMenu.showAt(e.x, e.y)
            discard app.gi.consume()
        else:
          app.contextMenu.clear()
          app.contextMenu.addItem("cut", "Cut", proc() = discard)
          app.contextMenu.addItem("copy", "Copy", proc() = discard)
          app.contextMenu.addItem("paste", "Paste", proc() = discard)
          app.contextMenu.showAt(e.x, e.y)
          discard app.gi.consume()

    if e.kind == MouseMoveEvent:
      if app.sidebarDragging:
        let delta = e.x - app.sidebarDragStartX
        app.sidebarWidth = clamp(app.sidebarWidth + delta, 120, app.width - 200)
        app.sidebarDragStartX = e.x
      if app.aiPanelDragging:
        let delta = app.aiPanelDragStartX - e.x
        app.aiPanelWidth = clamp(app.aiPanelWidth + delta, 200, app.width - 200)
        app.aiPanelDragStartX = e.x
      if app.terminalDragging:
        let delta = app.terminalDragStartY - e.y
        app.terminalHeight = clamp(app.terminalDragStartHeight + delta, TerminalMinHeight, TerminalMaxHeight)
      if not editorBounds.contains(point(e.x, e.y)):
        if app.lspThread != nil: app.lspThread.cancelHover()
        app.clearHoverState()
      if app.tooltip.visible and (abs(e.x - app.hoverMouseX) > 10 or abs(e.y - app.hoverMouseY) > 10):
        app.tooltip.hideTooltip()
        if app.lspThread != nil: app.lspThread.cancelHover()
        app.clearHoverState(clearPending = false)

    if e.kind == MouseUpEvent:
      app.sidebarDragging = false
      app.aiPanelDragging = false
      app.terminalDragging = false

    # Centralized cursor reconciliation keeps cursor state correct even when
    # UI changes via keyboard (without a mouse-move event).
    var desiredCursor = curDefault
    if app.sidebarDragging or app.aiPanelDragging:
      desiredCursor = curSizeWE
    elif app.terminalDragging:
      desiredCursor = curSizeNS
    elif app.rootNode != nil:
      desiredCursor = resolveCursor(app.rootNode, app.mouseX, app.mouseY)
    if desiredCursor != app.lastCursor:
      app.lastCursor = desiredCursor
      setCursor(desiredCursor)

    # Drawing

    # Title bar background
    fillRect(rect(0, 0, app.width, TopBarHeight), currentTheme.getColor(tcBackground))

    # Title bar buttons
    renderTitleBarButtons(app)

    # Tabs
    let tabsBounds = rect(TabBarStartX, 0, max(0, app.width - TabBarStartX), TopBarHeight)
    app.tabBar.render(app.uiFont, tabsBounds)

    # Sidebar
    if app.sidebarVisible:
      if app.showSearchPanel:
        app.searchPanel.pollWorkspaceSearch()
        let ed = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len: addr app.buffers[app.currentBuffer].ed else: nil
        app.searchPanel.render(ed, sidebarBounds)
      elif app.showGitPanel:
        app.gitPanel.render(sidebarBounds, app.uiFont)
      elif app.showDebugPanel:
        # Sync breakpoints to debug sidebar
        app.debugSidebar.breakpoints = @[]
        for bp in app.breakpoints:
          app.debugSidebar.breakpoints.add(debug_sidebar.Breakpoint(path: bp.path, line: bp.line, enabled: bp.enabled))
        app.debugSidebar.render(sidebarBounds, app.uiFont)
      else:
        app.fileExplorer.render(sidebarBounds, app.uiFont)

    # Right panel (AI)
    if app.aiPanelVisible:
      app.aiPanel.render(app.uiFont, layout.rightPanel)

    # Poll file watcher for changes
    for event in app.fileWatcher.pollEvents():
      let path = event.path
      case event.kind
      of feCreated, feModified:
        if path.fileExists:
          for i, b in app.buffers:
            if b.path == path:
              if not b.ed.changed:
                app.buffers[i].ed.loadFromFile(path)
              else:
                discard app.notificationManager.warning("File changed externally: " & path.extractFilename & " — reload skipped (unsaved changes)")
              break
        if path.dirExists or (path.parentDir.dirExists):
          app.fileExplorer.refresh()
      of feDeleted:
        let dirPath = path.parentDir
        if dirPath.dirExists:
          app.fileExplorer.refresh()

    # Poll LSP responses
    if app.lspThread != nil:
      var responses: seq[LSPMessage] = @[]
      while true:
        let respOpt = app.lspThread.getResponse()
        if respOpt.isNone:
          break
        responses.add(respOpt.get())
      # Process lmkReady first so didOpen fires before any pending diagnostics
      var pending: seq[LSPMessage] = @[]
      for resp in responses:
        if resp.kind == lmkReady:
          app.lspStarting = false
          stderr.writeLine("[app] LSP ready, notifying didOpen for all open .nim buffers")
          for b in app.buffers:
            if b.path.endsWith(".nim"):
              app.lspThread.notifyDidOpen(b.path, b.ed.fullText())
        else:
          pending.add(resp)
      for resp in pending:
        stderr.writeLine("[app] LSP response: " & $resp.kind)
        case resp.kind
        of lmkReady: discard  # already handled above
        of lmkError:
          app.lspStarting = false
          stderr.writeLine("[app] LSP error: " & resp.str1)
          discard app.notificationManager.error("LSP: " & resp.str1)
        of lmkHover:
          stderr.writeLine("[app] LSP response: lmkHover hasText=" & $resp.hoverText.isSome & " mouse=(" & $app.mouseX & "," & $app.mouseY & ") hoverMouse=(" & $app.hoverMouseX & "," & $app.hoverMouseY & ")")
          let hoverMatchesRequest = app.hoverRequestId >= 0 and
                                    resp.hoverReqId == app.hoverRequestId
          if not hoverMatchesRequest:
            stderr.writeLine("[app] ignoring stale hover response (respReqId=" & $resp.hoverReqId & ", expectedReqId=" & $app.hoverRequestId & ", respPath=" & resp.str1 & ")")
          elif resp.hoverText.isSome:
            # Only show if the mouse hasn't drifted too far from where the request was issued.
            # This avoids dropping the tooltip when the user jitters the mouse slightly
            # while the LSP response is in flight.
            let dx = abs(app.mouseX - app.hoverMouseX)
            let dy = abs(app.mouseY - app.hoverMouseY)
            if dx <= 40 and dy <= 40:
              stderr.writeLine("[app] showing tooltip, textLength=" & $resp.hoverText.get().len)
              app.tooltip.showTooltip(resp.hoverText.get(), app.mouseX, app.mouseY)
              app.hoverMouseX = app.mouseX
              app.hoverMouseY = app.mouseY
            else:
              stderr.writeLine("[app] tooltip rejected: mouse drifted dx=" & $dx & " dy=" & $dy)
            app.clearHoverState(clearPending = false)
          else:
            stderr.writeLine("[app] hover response is empty, hiding tooltip")
            if app.tooltip.visible:
              app.tooltip.hideTooltip()
            app.clearHoverState()
        of lmkDefinition:
          stderr.writeLine("[app] lmkDefinition received: locations=" & $resp.locations.len)
          for i, loc in resp.locations:
            stderr.writeLine("[app]   loc[" & $i & "] uri=" & loc.uri)
          app.showLocationPicker(resp.locations)
        of lmkDiagnostics:
          stderr.writeLine("[app] lmkDiagnostics received")
          try:
            app.handleDiagnostics(resp.jsonData)
          except CatchableError as e:
            stderr.writeLine("[app] handleDiagnostics error: " & e.msg)
        of lmkShowMessage:
          case resp.int1
          of 1: discard app.notificationManager.error(resp.str1)
          of 2: discard app.notificationManager.warning(resp.str1)
          else: discard app.notificationManager.info(resp.str1)
        else:
          discard

    # Poll DAP responses
    if app.dapThread != nil:
      while true:
        let respOpt = app.dapThread.getResponse()
        if respOpt.isNone:
          break
        let resp = respOpt.get()
        stderr.writeLine("[app] DAP response: " & $resp.kind)
        case resp.kind
        of dmkReady:
          app.dapStarting = false
          stderr.writeLine("[app] DAP ready")
          if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
            let b = app.buffers[app.currentBuffer]
            if b.path.len > 0:
              var lines: seq[int] = @[]
              for bp in app.breakpoints:
                if bp.path == b.path and bp.enabled:
                  lines.add(bp.line)
              app.dapThread.requestSetBreakpoints(b.path, lines)
              app.dapThread.requestLaunch(b.path.changeFileExt(""), cwd = b.path.parentDir, stopOnEntry = false)
              app.dapThread.requestConfigurationDone()
              app.debugPanel.status = "Running"
        of dmkError:
          app.dapStarting = false
          app.debugSessionActive = false
          stderr.writeLine("[app] DAP error: " & resp.str1)
          discard app.notificationManager.error("DAP: " & resp.str1)
          app.debugPanel.status = "Error"
        of dmkStopped:
          app.debugStopped = true
          app.debugStopThreadId = resp.int1
          app.debugPanel.status = "Stopped"
          stderr.writeLine("[app] DAP stopped: reason=" & resp.str1 & " threadId=" & $resp.int1)
          if app.dapThread != nil and app.dapThread.isReady.load(moAcquire) and resp.int1 > 0:
            app.dapThread.requestStackTrace(resp.int1)
          # Try to navigate to stop location if description contains path:line
          if resp.str2.len > 0:
            app.debugPanel.addOutput("Stopped: " & resp.str1 & " - " & resp.str2)
          else:
            app.debugPanel.addOutput("Stopped: " & resp.str1)
        of dmkOutput:
          app.debugPanel.addOutput(resp.str2)
        of dmkTerminated:
          app.debugSessionActive = false
          app.debugStopped = false
          app.debugStopThreadId = 0
          app.debugPanel.status = "Terminated"
          app.debugPanel.addOutput("Debug session terminated")
        of dmkStackTraceResponse:
          if resp.jsonData != nil and resp.jsonData.hasKey("body") and resp.jsonData["body"].hasKey("stackFrames"):
            var frames: seq[debug_panel.StackFrame] = @[]
            for item in resp.jsonData["body"]["stackFrames"]:
              let id = if item.hasKey("id"): item["id"].getInt() else: 0
              let name = if item.hasKey("name"): item["name"].getStr() else: ""
              var source = ""
              var line = 0
              var column = 0
              if item.hasKey("source") and item["source"].hasKey("path"):
                source = item["source"]["path"].getStr()
              if item.hasKey("line"):
                line = item["line"].getInt() - 1  # Convert to 0-based
              if item.hasKey("column"):
                column = item["column"].getInt() - 1
              frames.add(debug_panel.StackFrame(id: id, name: name, source: source, line: line, column: column))
            app.debugPanel.frames = frames
            # Sync frames to debug sidebar
            app.debugSidebar.frames = @[]
            for f in frames:
              app.debugSidebar.frames.add(debug_sidebar.StackFrame(id: f.id, name: f.name, source: f.source, line: f.line, column: f.column))
            # Auto-navigate to top frame
            if frames.len > 0 and frames[0].source.len > 0:
              let idx = app.openBuffer(frames[0].source)
              if idx >= 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
                app.buffers[app.currentBuffer].ed.gotoLine(frames[0].line, frames[0].column)
        of dmkVariablesResponse:
          discard  # TODO: show variables in debug panel
        else:
          discard
        # Sync debug panel status to sidebar
        app.debugSidebar.status = app.debugPanel.status

    # Poll AI responses
    if app.aiThread != nil:
      while true:
        let respOpt = app.aiThread.getResponse()
        if respOpt.isNone:
          break
        let resp = respOpt.get()
        case resp.kind
        of amkReady:
          stderr.writeLine("[app] AI thread ready")
        of amkResponseChunk:
          app.aiPanel.appendText(resp.text)
        of amkResponseDone:
          app.aiPanel.finalizeMessage()
        of amkThinking:
          app.aiPanel.appendText(resp.text)
        of amkFileChanged:
          let path = resp.text
          stderr.writeLine("[app] AI changed file: " & path)
          for i, b in app.buffers:
            if b.path == path:
              if b.ed.changed:
                discard app.notificationManager.warning("AI modified " & extractFilename(path) & " — reload skipped (unsaved changes)")
              else:
                try:
                  app.buffers[i].ed.loadFromFile(path)
                except CatchableError:
                  discard
              break
          app.fileExplorer.refresh()
        of amkCancel:
          app.aiPanel.finalizeMessage()
          app.aiPanel.isStreaming = false
        of amkError:
          stderr.writeLine("[app] AI error: " & resp.error)
          app.aiPanel.appendText("Error: " & resp.error)
          app.aiPanel.finalizeMessage()
          discard app.notificationManager.error("AI: " & resp.error)
        else:
          discard

    # Diff View (replaces editor when active)
    if isDiffBuffer and app.diffView != nil:
      app.diffView.render(editorBounds, app.font, app.focus == "editor")
    elif app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
      let idx = app.currentBuffer
      if app.buffers[idx].isImage:
        # Draw image centered in editor bounds, preserving aspect ratio
        let b = app.buffers[idx]
        if b.image.int != 0:
          let availW = editorBounds.w.float
          let availH = editorBounds.h.float
          let imgW = b.imageWidth.float
          let imgH = b.imageHeight.float
          var drawW = imgW
          var drawH = imgH
          if imgW > availW or imgH > availH:
            let scaleW = availW / imgW
            let scaleH = availH / imgH
            let scale = min(scaleW, scaleH)
            drawW = imgW * scale
            drawH = imgH * scale
          let dstX = editorBounds.x + int((availW - drawW) / 2)
          let dstY = editorBounds.y + int((availH - drawH) / 2)
          drawImage(b.image, rect(0, 0, b.imageWidth, b.imageHeight),
                    rect(dstX, dstY, int(drawW), int(drawH)))
      else:
        var edEvent = e
        if app.gi.isConsumed:
          # If any node in the tree consumed the event (e.g. editorNode.onMouseMove
          # wrongly returning true), SynEdit receives NoEvent and cannot probe.
          edEvent = default Event
        let editorHovered = e.kind == MouseWheelEvent and editorBounds.contains(point(e.x, e.y))
        let edAct = app.buffers[idx].ed.draw(edEvent, editorBounds, app.focus == "editor" or editorHovered)
        case edAct.kind
        of ctrlHover:
          if e.kind == MouseMoveEvent and app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.buffers[idx].path.len > 0:
            if edAct.pos != app.hoverPendingPos:
              app.hoverPendingPos = edAct.pos
              let (line, col) = bufferPosToLineCol(app.buffers[idx].ed.fullText(), edAct.pos)
              app.hoverPendingLine = line
              app.hoverPendingCol = col
              app.hoverPendingTick = getTicks() + 400
              stderr.writeLine("[app] ctrlHover pending: pos=" & $edAct.pos & " line=" & $line & " col=" & $col)
        of ctrlClick:
          if app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.buffers[idx].path.len > 0:
            let (line, col) = bufferPosToLineCol(app.buffers[idx].ed.fullText(), edAct.pos)
            app.lspThread.requestDefinition(app.buffers[idx].path, line, col)
        of noAction:
          if e.kind == MouseMoveEvent:
            # Mouse moved off a hoverable symbol: drop delayed trigger only.
            # Keep any in-flight request so valid responses can still arrive.
            app.clearPendingHover()

        # Update buffer lines for sticky scroll and color highlighting
        let ed = app.buffers[idx].ed
        let cid = ed.cacheId
        if cid != app.lastColorScanCacheIds[idx]:
          app.lastColorScanCacheIds[idx] = cid
          let full = ed.fullText()
          app.bufferLines[idx] = full.splitLinesKeep()
          let colors = scanColorHighlights(full)
          app.bufferMarkers[idx].setMarkers(msColorHighlight, colors)
          applyMarkers(app.buffers[idx].ed, app.bufferMarkers[idx])
          applyLineDecorations(app, idx)

        # Sticky scroll overlay
        let sticky = computeStickyLines(app.bufferLines[idx], ed.firstLine, 5)
        if sticky.len > 0:
          let lineH = fontLineSkip(app.font)
          let gutterW = if ed.showLineNumbers: ed.spaceForLines() else: 0
          let stickyBg = currentTheme.getColor(tcBackground)
          let stickyBorder = currentTheme.getColor(tcBorder)
          let lineNumC = currentTheme.getColor(tcTextSecondary)
          for i, sl in sticky:
            let y = editorBounds.y + i * lineH
            let textX = editorBounds.x + gutterW + 4
            fillRect(rect(editorBounds.x, y, editorBounds.w, lineH), stickyBg)
            fillRect(rect(editorBounds.x, y + lineH - 1, editorBounds.w, 1), stickyBorder)
            if ed.showLineNumbers:
              discard drawText(app.font, editorBounds.x + 2, y + 2, $(sl.line + 1), lineNumC, color(0, 0, 0, 0))
            # Draw with character-by-character syntax highlighting
            let textColor = currentTheme.getColor(tcText)
            drawHighlightedLine(app.font, textX, y + 2, sl.text, ed.theme, textColor)

        # Git diff indicators on scrollbar
        let hasScrollBar = ed.span > 0 and ed.span.Natural <= app.bufferLines[idx].len
        if hasScrollBar and app.lastDiffLines[idx].len > 0:
          let trackX = editorBounds.x + editorBounds.w - ScrollBarWidth
          let trackH = editorBounds.h.float
          let totalLines = app.bufferLines[idx].len + ed.span
          if totalLines > 0:
            let markerW = ScrollBarWidth - 4
            let markerX = trackX + 2
            for dl in app.lastDiffLines[idx]:
              let lineRatio = clamp(dl.line.float / totalLines.float, 0.0, 1.0)
              let markerY = editorBounds.y + int(lineRatio * trackH)
              let markerH = max(2, int(trackH / totalLines.float))
              let markerColor = case dl.kind
                of 'A': currentTheme.getColor(tcSuccess)
                of 'M': currentTheme.getColor(tcWarning)
                of 'D': currentTheme.getColor(tcError)
                else: currentTheme.getColor(tcTextSecondary)
              fillRect(rect(markerX, markerY, markerW, markerH), markerColor)
    else:
      if app.screen == asWorkspace:
        discard drawText(app.font, editorBounds.x + 12, editorBounds.y + 12,
                         "No file open", color(150, 150, 150), color(0, 0, 0, 0))

    # Delayed hover trigger
    if app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and app.buffers[app.currentBuffer].path.len > 0 and
       getTicks() >= app.hoverPendingTick:
      let idx = app.currentBuffer
      stderr.writeLine("[app] hover trigger fired: pos=" & $app.hoverPendingPos & " line=" & $app.hoverPendingLine & " col=" & $app.hoverPendingCol & " mouse=(" & $app.mouseX & "," & $app.mouseY & ")")
      app.lspThread.cancelHover()
      inc app.hoverNextRequestId
      app.lspThread.requestHover(app.buffers[idx].path, app.hoverPendingLine, app.hoverPendingCol, app.hoverNextRequestId)
      app.hoverRequestId = app.hoverNextRequestId
      app.hoverRequestPos = app.hoverPendingPos
      app.hoverRequestPath = app.buffers[idx].path
      app.hoverMouseX = app.mouseX
      app.hoverMouseY = app.mouseY
      app.hoverPendingTick = high(int)

    # Status bar
    app.updateStatus()
    app.statusBar.render(app.statusFont, statusBounds)

    # Terminal / Problems bottom panel
    if app.showTerminal:
      # Panel border
      let borderC = currentTheme.getColor(tcBorder)
      fillRect(rect(termBounds.x, termBounds.y, termBounds.w, 1), borderC)
      fillRect(rect(termBounds.x, termBounds.y + termBounds.h - 1, termBounds.w, 1), borderC)
      fillRect(rect(termBounds.x, termBounds.y, 1, termBounds.h), borderC)
      fillRect(rect(termBounds.x + termBounds.w - 1, termBounds.y, 1, termBounds.h), borderC)

      # Focus border around entire panel
      if app.focus == "term":
        let accentC = currentTheme.getColor(tcAccent)
        fillRect(rect(termBounds.x, termBounds.y, termBounds.w, 1), accentC)
        fillRect(rect(termBounds.x, termBounds.y + termBounds.h - 1, termBounds.w, 1), accentC)
        fillRect(rect(termBounds.x, termBounds.y, 1, termBounds.h), accentC)
        fillRect(rect(termBounds.x + termBounds.w - 1, termBounds.y, 1, termBounds.h), accentC)

      # Tab strip header
      let tabStripBounds = termHeaderBounds
      fillRect(tabStripBounds, currentTheme.getColor(tcSurface))
      fillRect(rect(tabStripBounds.x, tabStripBounds.y, tabStripBounds.w, 1), borderC)
      fillRect(rect(tabStripBounds.x, tabStripBounds.y + tabStripBounds.h - 1, tabStripBounds.w, 1), borderC)

      # Draw tab buttons: "Problems", "Terminal", "Debug"
      let tabW = 90
      let accentC = currentTheme.getColor(tcAccent)
      let tabLabels = ["Problems", "Terminal", "Debug"]
      for ti, lbl in tabLabels:
        let tx = tabStripBounds.x + ti * tabW
        let tabBounds = rect(tx, tabStripBounds.y, tabW, tabStripBounds.h)
        let isActive = (ti == 0 and app.bottomPanelTab == "problems") or
                       (ti == 1 and app.bottomPanelTab == "terminal") or
                       (ti == 2 and app.bottomPanelTab == "debug")
        if isActive:
          fillRect(tabBounds, currentTheme.getColor(tcBackground))
          fillRect(rect(tx, tabStripBounds.y + tabStripBounds.h - 2, tabW, 2), accentC)
        discard drawText(app.font, tx + 8, tabStripBounds.y + 4, lbl,
                         currentTheme.getColor(tcText), color(0, 0, 0, 0))

      # Close button and drag handle on the right
      discard drawText(app.font, tabStripBounds.x + tabStripBounds.w - 20, tabStripBounds.y + 4,
                       "×", currentTheme.getColor(tcTextSecondary), color(0, 0, 0, 0))
      let handleX = tabStripBounds.x + tabStripBounds.w - 50
      for i in 0..2:
        fillRect(rect(handleX + i * 6, tabStripBounds.y + 8, 4, 4),
                 currentTheme.getColor(tcTextSecondary))

      # Content area
      if app.bottomPanelTab == "problems":
        app.diagPanel.render(termContentBounds, app.font, app.uiFont)
      elif app.bottomPanelTab == "debug":
        app.debugPanel.render(termContentBounds, app.font, app.uiFont)
      else:
        # Terminal content
        var termEvent = e
        if app.gi.isConsumed:
          termEvent = default Event
        elif e.kind == MouseDownEvent or e.kind == MouseMoveEvent or e.kind == MouseUpEvent:
          if e.y >= termHeaderBounds.y and e.y < termHeaderBounds.y + termHeaderBounds.h:
            termEvent = default Event
        let termHovered = e.kind == MouseWheelEvent and termContentBounds.contains(point(e.x, e.y))
        let termAct = app.term.draw(termEvent, termContentBounds, app.focus == "term" or termHovered)
        case termAct.kind
        of openFile:
          if fileExists(termAct.file):
            discard app.openBuffer(termAct.file)
        of saveFile:
          discard app.saveCurrentBuffer()
        of ctrlHover, ctrlClick, noAction:
          discard
    # Welcome screen (behind overlays)
    if app.screen == asWelcome:
      app.welcomeScreen.render(app.width, app.height, app.uiFont)

    # Overlays (in z-order)
    if app.themeSelector.isVisible:
      app.themeSelector.render(app.uiFont, rect(0, 0, app.width, app.height))
    if app.locationPicker.isVisible:
      app.locationPicker.render(app.uiFont, rect(0, 0, app.width, app.height))
    if app.commandPalette.isVisible:
      app.commandPalette.render(app.uiFont, rect(0, 0, app.width, app.height))
    app.dialogManager.render(app.width, app.height)
    app.inputDialog.render(app.width, app.height)
    app.contextMenu.render()
    app.lspMenu.render()
    app.branchMenu.render()
    app.notificationManager.update(delta)
    app.notificationManager.render()
    if app.tooltip.visible:
      app.tooltip.render(app.tooltipFont, app.width, app.height)

    refresh()

proc cleanup*(app: App) =
  stopAccessingAllSecurityScopedResources()
  if app.aiThread != nil:
    app.aiThread.shutdown()
  if app.lspThread != nil:
    app.lspThread.shutdown()
  if app.dapThread != nil:
    app.dapThread.shutdown()
  closeFont(app.font)
  if app.uiFont != app.font:
    closeFont(app.uiFont)
  if app.termFont != app.font:
    closeFont(app.termFont)
  if app.statusFont != app.font and app.statusFont != app.uiFont:
    closeFont(app.statusFont)
  if app.tooltipFont != app.font:
    closeFont(app.tooltipFont)
  shutdown()

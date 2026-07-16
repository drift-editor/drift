## Drift Editor - uirelays-based Application

import std/[os, osproc, strutils, json, options, monotimes, times, atomics, tables, sets, sequtils]
import uirelays
import chronos
from pixie import readImage
import widgets/[synedit, terminal]
import widgets/theme as synTheme
import ../ui/[tabs, command_palette, search_panel, notification, dialog, context_menu, file_explorer, git_panel, welcome_screen, theme, hover_tooltip, file_dialog, statusbar, icons, theme_loader, theme_selector, location_picker, node, diagnostics_panel, ai_panel, debug_panel, debug_sidebar, model_select_dialog]
import explorer_context
import ../services/[lsp_thread, lsp_client, ai_thread, ai_model_detector, builtin_ai]
import ../services/dap_thread
import ../services/git as gitcmd
import ../core/types
import ../core/config as cfg
import ../core/search_history
import ../core/debug_types
import ../core/recent_files
import ../core/keybindings as kb
import ../editor/[marker_manager, color_highlight, git_diff, sticky_scroll, auto_close]
import ../utils/text
import ../utils/file_watcher
import ../utils/file
import app_layout, app_cursors, event_router, app_tree, app_commands, app_palette, commands
import ../ui/diff_view

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
    lastEditTick: int
    lastSaveTick: int
    lastChanged: bool

  ClosedTabInfo* = object
    path*: string
    line*: int
    col*: int

  App* = ref object
    config*: cfg.AppConfig
    initialAiAgent: string  ## Loaded default agent; not persisted when user switches agents at runtime.
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
    modelSelectDialog: ModelSelectDialog
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

    # Closed tab history
    closedTabs*: seq[ClosedTabInfo]

    # Clipboard ring
    clipboardHistory*: seq[string]
    clipboardHistoryIndex*: int

    # External change conflict suppression
    externalChangeSuppressed: HashSet[string]
    externalChangePending: HashSet[string]

    # LSP
    lspServer: string
    lspLanguage: string
    lspThread: LSPThread
    lspStarting: bool
    lspErrorMsg: string
    hoverMouseX, hoverMouseY: int

    # DAP
    dapThread: DAPThread
    debugState: DebugSessionState
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
    lastKeybindingsMtime: float
    lastBracketBuffer: int
    lastBracketCursorOff: int

const
  TerminalHeight = 200

proc editorTheme(app: App): synTheme.Theme =
  ## Build a SynEdit theme from the current UI theme, respecting bracketHighlight config.
  result = driftSyneditTheme()
  if not app.config.bracketHighlight:
    result.bracketBg = color(0, 0, 0, 0)

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
    app.buffers[i].ed.theme = app.editorTheme()
  app.term.ed.theme = driftSyneditTheme()
  if app.diffView != nil:
    app.diffView.leftEd.theme = driftSyneditTheme()
    app.diffView.rightEd.theme = driftSyneditTheme()
    app.diffView.applyDecorations()

proc saveAppConfig(app: App) =
  ## Persist config but keep the originally-loaded default agent,
  ## so runtime agent switches do not alter the saved default.
  var saved = app.config
  saved.aiAgent = app.initialAiAgent
  app.searchPanel.saveSearchState(saved)
  cfg.saveConfig(saved)
  saveSearchHistory(app.searchPanel.searchHistory)

proc applyTheme*(app: App, name: string) =
  if name.len == 0 or app.config.theme == name:
    return
  app.setTheme(name)
  app.config.theme = name
  saveAppConfig(app)


include app_ai


proc createApp*(config: cfg.AppConfig = cfg.defaultConfig()): App =
  var app = App(config: config, initialAiAgent: config.aiAgent, focus: "editor", screen: asWelcome, currentBuffer: -1, sidebarVisible: true, showGitPanel: false, showSearchPanel: false, showDebugPanel: false, terminalHeight: TerminalHeight, sidebarWidth: SidebarWidth, aiPanelVisible: false, aiPanelWidth: RightPanelWidth, hoverPendingPos: -1, hoverPendingTick: high(int), hoverRequestPos: -1, hoverRequestId: -1, aiPanel: newAIPanel("Ask " & agentLabel(config.aiAgent) & "..."), debugState: dssOff, debugStopThreadId: 0, breakpoints: @[], closedTabs: @[], clipboardHistory: @[], clipboardHistoryIndex: 0, externalChangeSuppressed: initHashSet[string](), externalChangePending: initHashSet[string]())
  app.aiPanel.subtitle = aiSubtitle(config)
  app.aiPanel.modelPreset = config.aiModelPreset
  proc sendAiPrompt(promptText: string) =
    if app.aiThread == nil:
      app.aiThread = newAIThread(app.config)
    app.aiThread.sendMessage(promptText)
    app.aiPanel.isStreaming = true

  app.aiPanel.onSend = proc(text: string) =
    # Build prompt with editor context (slim: path + cursor line + selection only)
    var promptText = text
    if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
      let b = app.buffers[app.currentBuffer]
      if not b.isImage and b.path.len > 0:
        promptText = "Current file: " & b.path & "\nCursor at line " & $(b.ed.currentLine + 1)
        let selText = b.ed.getSelectedText()
        if selText.len > 0 and selText.len < 2000:
          promptText &= "\nSelected text:\n```\n" & selText & "\n```"
        promptText &= "\n\n" & text
    sendAiPrompt(promptText)
  app.aiPanel.onNewSession = proc() =
    if app.aiThread != nil:
      app.aiThread.newSession()
    app.aiPanel.clearChat()
  app.aiPanel.onStop = proc() =
    if app.aiThread != nil:
      app.aiThread.cancel()
  app.aiPanel.showModelControls = isHttpAgent(config.aiAgent)
  app.aiPanel.onAgentMenu = proc(x, y: int) =
    app.contextMenu.clear()
    for p in CommonAgents:
      app.contextMenu.addItem(p.id, p.label, app.makeSelectAgentAction(p.id))
    if isHttpAgent(app.config.aiAgent):
      app.contextMenu.addSeparator()
      app.contextMenu.addItem("apikey", "Set API Key", proc() = app.promptApiKey())
      app.contextMenu.addItem("baseurl", "Set Base URL", proc() = app.promptBaseUrl())
    app.contextMenu.showAt(x, y, app.width, app.height)
    discard app.gi.consume()
  app.aiPanel.onModelMenu = proc(x, y: int) =
    app.showUnifiedModelDialog()
  app.aiPanel.onPlanModeToggle = proc() =
    app.aiPanel.planMode = not app.aiPanel.planMode
    if app.aiThread != nil:
      app.aiThread.togglePlanMode()
  app.aiPanel.onVariantsMenu = proc(x, y: int) =
    # Reasoning-effort variants are provider-specific; build from the active model.
    let (providerId, _) = cfg.effectiveModel(app.config)
    app.contextMenu.clear()
    for eff in reasoningVariants(providerId):
      app.contextMenu.addItem(eff, capitalizeAscii(eff), app.makeSelectEffortAction(eff))
    app.contextMenu.showAt(x, y, app.width, app.height)
    discard app.gi.consume()
  app.refreshThinkingControls()
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


include app_lang
include app_status
include app_buffers
include app_lsp
include app_git


include app_debug

# Forward declarations for public API procs defined after init.
proc openFile*(app: App, path: string): bool
proc openFolder*(app: App, path: string)
proc newFile*(app: App)

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
  setTheme(loadThemeByName(app.config.theme))

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
  app.debugPanel.onVariablesRequest = proc(variablesReference: int) =
    if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
      app.dapThread.requestVariables(variablesReference)
  app.debugPanel.onEvaluate = proc(expression: string) =
    if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
      app.dapThread.requestEvaluate(expression)
    else:
      app.debugPanel.addOutput("Debug session not ready")
  app.debugPanel.onEditVariableRequest = proc(node: DebugTreeNode) =
    app.inputDialog.title = "Set Variable"
    app.inputDialog.prompt = "New value for " & node.name & ":"
    app.inputDialog.text = node.value
    app.inputDialog.centerOnScreen(app.width, app.height)
    app.inputDialog.onResult = proc(confirmed: bool, text: string) =
      if confirmed:
        app.debugPanel.confirmSetVariable(text)
    app.inputDialog.show()
  app.debugPanel.onSetVariable = proc(variablesReference: int; name: string; value: string) =
    if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
      app.dapThread.requestSetVariable(variablesReference, name, value)
    else:
      app.debugPanel.addOutput("Debug session not ready")
  app.debugPanel.onInputFocus = proc() =
    app.focus = "debugPanel"

  # Debug sidebar
  app.debugSidebar = newDebugSidebar()
  app.debugSidebar.onStartDebug = proc() =
    app.startOrContinueDebugging()
  app.debugSidebar.onStopDebug = proc() =
    app.stopDebugging()
  app.debugSidebar.onContinue = proc() =
    app.continueDebugging()
  app.debugSidebar.onStepOver = proc() =
    app.stepOverDebugging()
  app.debugSidebar.onStepInto = proc() =
    app.stepIntoDebugging()
  app.debugSidebar.onStepOut = proc() =
    app.stepOutDebugging()
  app.debugSidebar.onNavigate = proc(path: string; line, col: int) =
    if path.len == 0: return
    let idx = app.openBuffer(path)
    if idx >= 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
      app.buffers[app.currentBuffer].ed.gotoLine(line, col)

  # LSP
  app.lspLanguage = "nim"
  app.lspServer = app.lspServerForLanguage("nim")
  if app.lspServer.len == 0:
    app.lspServer = "minlsp"

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
  app.searchPanel = newSearchPanel(app.uiFont, app.uiFm, app.config)
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
  app.modelSelectDialog = newModelSelectDialog(app.uiFont)

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
        app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)
  app.welcomeScreen.onShowTooltip = proc(text: string; x, y: int) =
    app.tooltip.showTooltip(text, x, y)
  app.welcomeScreen.onHideTooltip = proc() =
    app.tooltip.hideTooltip()
  app.welcomeScreen.onShowDocumentation = proc() =
    let readme = getAppDir() / "README.md"
    if fileExists(readme):
      discard app.openBuffer(readme)
      app.hideWelcome()
  app.welcomeScreen.onPinToggle = proc(path: string; pinned: bool) =
    if pinned:
      if path notin app.config.pinnedRecentFiles:
        app.config.pinnedRecentFiles.insert(path, 0)
    else:
      app.config.pinnedRecentFiles.keepItIf(it != path)
    saveAppConfig(app)

  # Load persisted recent files
  app.recentFiles = loadRecentFiles()
  app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)

  # Load persisted search history separately from config.
  let persistedSearchHistory = loadSearchHistory()
  if persistedSearchHistory.len > 0:
    app.searchPanel.searchHistory = mergeSearchHistory(app.searchPanel.searchHistory, persistedSearchHistory)
    if app.searchPanel.searchHistory.len > 0 and app.searchPanel.findText.len == 0 and app.config.searchRememberOptions:
      app.searchPanel.findText = app.searchPanel.searchHistory[^1]
      app.searchPanel.findCursor = app.searchPanel.findText.len

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

  # Command palette (registered in app_palette.nim)
  registerPaletteCommands(app)


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

  # 2. Recent files (skip folders 锟?quick open is for files only)
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

proc showSymbolPicker*(app: App, path: string, symbols: seq[LSPSymbol]) =
  ## Show a picker for LSP document/workspace symbols.
  if symbols.len == 0:
    discard app.notificationManager.info("No symbols found")
    return
  if symbols.len == 1:
    let s = symbols[0]
    let loc = Location(uri: s.uri, range: s.range)
    if app.locationPicker.onSelect != nil:
      app.locationPicker.onSelect(loc)
    return

  var items: seq[LocationItem] = @[]
  for s in symbols:
    let loc = Location(uri: s.uri, range: s.range)
    items.add(LocationItem(display: s.name, loc: loc))
  app.locationPicker.show(items, app.mouseX, app.mouseY)


proc reloadKeybindingsIfChanged(app: App) =
  ## Hot-reload keybindings.toml when its mtime changes.
  let path = kb.keybindingsPath()
  if not fileExists(path):
    return
  let mtime = getFileInfo(path).lastWriteTime.toUnixFloat()
  if app.lastKeybindingsMtime <= 0:
    app.lastKeybindingsMtime = mtime
    return
  if abs(mtime - app.lastKeybindingsMtime) < 0.5:
    return
  app.lastKeybindingsMtime = mtime
  let overrides = kb.loadKeybindings(path)
  var applied = 0
  for cmdId, binding in overrides.pairs:
    if app.commands.hasCommand(cmdId):
      app.commands.bindKey(binding.mods, binding.key, cmdId)
      inc applied
    else:
      stderr.writeLine("[keybindings] unknown command id: " & cmdId)
  if applied > 0:
    stderr.writeLine("[keybindings] hot-reloaded " & $applied & " override(s)")

proc run*(app: App) =
  # Command system init (done here so template can see all app procs)
  initCommands(app)

  # Apply user keybinding overrides from ~/.config/drift/keybindings.toml
  kb.ensureDefaultKeybindingsFile(kb.keybindingsPath())
  let kbOverrides = kb.loadKeybindings(kb.keybindingsPath())
  for cmdId, binding in kbOverrides.pairs:
    if app.commands.hasCommand(cmdId):
      app.commands.bindKey(binding.mods, binding.key, cmdId)
    else:
      stderr.writeLine("[keybindings] unknown command id: " & cmdId)

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
    elif app.modelSelectDialog.isVisible and app.modelSelectDialog.handleInput(e):
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
      elif app.focus == "debugPanel" and app.bottomPanelTab == "debug":
        if app.debugPanel.handleKey(e):
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
      elif app.focus == "debugPanel" and app.bottomPanelTab == "debug":
        if app.debugPanel.handleTextInput(e):
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
      # Status bar click handling for line-ending / encoding sections.
      if e.button == LeftButton:
        let idx = rightSectionIndexAt(app, statusBounds, e.x, e.y)
        if idx == app.statusBar.lineEndingIndex and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
          var b = app.buffers[app.currentBuffer]
          if b.path.len > 0 and not b.isImage and b.diffPath.len == 0:
            let text = b.ed.fullText
            let hasCRLF = text.contains("\c\L")
            if hasCRLF:
              b.ed.setText(text.replace("\c\L", "\L"))
            else:
              b.ed.setText(text.replace("\L", "\c\L"))
            b.ed.markChanged()
            b.lastChanged = true
            app.tabBar.updateTabModified($app.currentBuffer, true)
            app.updateTitle()
            app.updateStatus()
            discard app.gi.consume()
        elif idx == app.statusBar.encodingIndex and app.statusBar.encodingIndex >= 0:
          # UTF-8 is the only supported encoding for now; show a notification.
          discard app.notificationManager.info("Encoding is fixed to UTF-8")
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
          callbacks.onCopyPath = proc(path: string) =
            putClipboardText(path)
            app.pushClipboardHistory(path)
          callbacks.onCopyRelativePath = proc(path: string) =
            let rel = relativePath(path, app.fileExplorer.rootPath)
            putClipboardText(rel)
            app.pushClipboardHistory(rel)
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
            let clickedIdx = app.aiPanel.messageIndexAt(e.y, app.uiFont, layout.rightPanel)
            if clickedIdx >= 0:
              app.contextMenu.addItem("copy", "Copy Message", proc() =
                discard app.aiPanel.copyMessageAt(clickedIdx))
            app.contextMenu.addItem("copyLast", "Copy Last Message", proc() =
              discard app.aiPanel.copyLastAssistantMessage())
            app.contextMenu.addSeparator()
            app.contextMenu.addItem("clear", "Clear Conversation", proc() =
              app.aiPanel.clearChat()
              if app.aiPanel.onNewSession != nil:
                app.aiPanel.onNewSession())
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
        const minEditorWidth = 400
        let maxPanelWidth = max(200, app.width - minEditorWidth)
        app.aiPanelWidth = clamp(app.aiPanelWidth + delta, 200, maxPanelWidth)
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
      # Status bar hover tracking for line-ending/encoding sections.
      app.statusBar.hoverRightIndex = rightSectionIndexAt(app, statusBounds, e.x, e.y)
      # Show a tooltip when hovering the LSP status section.
      if app.statusBar.lspIndex >= 0 and app.statusBar.hoverRightIndex == app.statusBar.lspIndex:
        let text = app.lspStatusTooltip()
        app.tooltip.showTooltip(text, app.mouseX, app.mouseY)
      elif app.tooltip.visible and app.statusBar.hoverRightIndex != app.statusBar.lspIndex:
        # Hide tooltip when leaving the LSP section (but leave editor hover tooltips alone
        # unless the mouse is clearly over the status bar).
        let statusHovered = rightSectionIndexAt(app, statusBounds, app.mouseX, app.mouseY) >= 0
        if statusHovered:
          app.tooltip.hideTooltip()

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
    fillRect(rect(0, TopBarHeight - 1, app.width, 1), currentTheme.getColor(tcBorder))

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
          app.debugSidebar.breakpoints.add(Breakpoint(path: bp.path, line: bp.line, enabled: bp.enabled))
        app.debugSidebar.render(sidebarBounds, app.uiFont)
      else:
        app.fileExplorer.render(sidebarBounds, app.uiFont)

    # Right panel (AI)
    if app.aiPanelVisible:
      # Drop the input's focused (accent) border when focus is elsewhere.
      # While focus is on the panel, keep its finer input/messages state intact.
      if app.focus != "aiPanel":
        app.aiPanel.focused = false
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
                app.buffers[i].lastSaveTick = getTicks()
                app.buffers[i].lastChanged = false
                app.tabBar.updateTabModified($i, false)
                if i == app.currentBuffer:
                  app.updateTitle()
                  app.updateStatus()
                app.externalChangeSuppressed.excl(path)
                app.externalChangePending.excl(path)
              else:
                if app.config.fileWatcherAutoReload:
                  if path notin app.externalChangePending:
                    let wasSuppressed = path in app.externalChangeSuppressed
                    if wasSuppressed:
                      app.externalChangeSuppressed.excl(path)
                    if not wasSuppressed:
                      let reloadPath = path
                      let bufferIdx = i
                      let filename = reloadPath.extractFilename
                      let dlg = newDialog("File Changed Externally", filename & " has changed on disk. Reload and discard your changes?", app.uiFont)
                      dlg.buttons = @[
                        DialogButton(label: "Reload", result: drOk, isDefault: true),
                        DialogButton(label: "Keep", result: drCancel, isCancel: true)
                      ]
                      dlg.onResult = proc(res: DialogResult) =
                        app.externalChangePending.excl(reloadPath)
                        if res == drOk and bufferIdx >= 0 and bufferIdx < app.buffers.len and app.buffers[bufferIdx].path == reloadPath:
                          app.buffers[bufferIdx].ed.loadFromFile(reloadPath)
                          app.buffers[bufferIdx].lastSaveTick = getTicks()
                          app.buffers[bufferIdx].lastChanged = false
                          app.tabBar.updateTabModified($bufferIdx, false)
                          if bufferIdx == app.currentBuffer:
                            app.updateTitle()
                            app.updateStatus()
                          app.externalChangeSuppressed.excl(reloadPath)
                        elif res == drCancel:
                          app.externalChangeSuppressed.incl(reloadPath)
                      dlg.centerOnScreen(app.width, app.height)
                      app.externalChangePending.incl(reloadPath)
                      app.dialogManager.show(dlg)
                else:
                  discard app.notificationManager.warning("File changed externally: " & path.extractFilename & " 锟?reload skipped (unsaved changes)")
              break
        if path.dirExists or (path.parentDir.dirExists):
          app.fileExplorer.refresh()
      of feDeleted:
        let dirPath = path.parentDir
        if dirPath.dirExists:
          app.fileExplorer.refresh()

    # Auto-save dirty buffers after delay
    app.checkAutoSave()

    # Update bracket-match markers when cursor moves
    app.updateBracketMatchMarkers()

    # Hot-reload keybindings periodically
    app.reloadKeybindingsIfChanged()

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
          stderr.writeLine("[app] LSP ready, notifying didOpen for all open " & app.lspLanguage & " buffers")
          for b in app.buffers:
            if languageIdFor(b.path) == app.lspLanguage:
              app.lspThread.notifyDidOpen(b.path, b.ed.fullText())
        else:
          pending.add(resp)
      for resp in pending:
        stderr.writeLine("[app] LSP response: " & $resp.kind)
        case resp.kind
        of lmkError:
          app.lspStarting = false
          app.lspErrorMsg = resp.str1
          stderr.writeLine("[app] LSP error: " & resp.str1)
          discard app.notificationManager.error("LSP: " & resp.str1)
        of lmkReady:
          app.lspErrorMsg = ""
          discard  # already handled above
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
        of lmkFormat:
          stderr.writeLine("[app] lmkFormat received: edits=" & $resp.edits.len)
          if resp.edits.len > 0:
            var found = false
            for i in 0 ..< app.buffers.len:
              if app.buffers[i].path == resp.str1:
                app.applyLspEditsToBuffer(i, resp.edits)
                found = true
                break
            if found:
              app.updateTitle()
              app.updateStatus()
              discard app.notificationManager.info("Document formatted")
            else:
              discard app.notificationManager.warning("Format response for closed buffer")
        of lmkRename:
          stderr.writeLine("[app] lmkRename received: changes=" & $resp.workspaceEdit.changes.len)
          var applied = 0
          for uri, edits in resp.workspaceEdit.changes:
            let path = decodeFileUri(uri)
            var idx = -1
            for i in 0 ..< app.buffers.len:
              if app.buffers[i].path == path:
                idx = i
                break
            if idx < 0 and fileExists(path):
              idx = app.openBuffer(path)
            if idx >= 0:
              app.applyLspEditsToBuffer(idx, edits)
              inc applied
          if applied > 0:
            app.updateTitle()
            app.updateStatus()
            discard app.notificationManager.info("Renamed symbol in " & $applied & " file(s)")
          else:
            discard app.notificationManager.info("No rename changes applied")
        of lmkReferences:
          stderr.writeLine("[app] lmkReferences received: locations=" & $resp.locations.len)
          if resp.locations.len > 0:
            app.showLocationPicker(resp.locations)
          else:
            discard app.notificationManager.info("No references found")
        of lmkDocumentSymbols:
          stderr.writeLine("[app] lmkDocumentSymbols received: symbols=" & $resp.symbols.len)
          if resp.symbols.len > 0:
            app.showSymbolPicker(resp.str1, resp.symbols)
          else:
            discard app.notificationManager.info("No symbols found")
        of lmkWorkspaceSymbols:
          stderr.writeLine("[app] lmkWorkspaceSymbols received: symbols=" & $resp.symbols.len)
          if resp.symbols.len > 0:
            app.showSymbolPicker("", resp.symbols)
          else:
            discard app.notificationManager.info("No workspace symbols found")
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
    while app.dapThread != nil:
      let respOpt = app.dapThread.getResponse()
      if respOpt.isNone:
        break
      let resp = respOpt.get()
      stderr.writeLine("[app] DAP response: " & $resp.kind)
      case resp.kind
      of dmkReady:
        app.debugState = dssReady
        stderr.writeLine("[app] DAP ready")
        if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
          let b = app.buffers[app.currentBuffer]
          if b.path.len > 0:
            var lines: seq[int] = @[]
            for bp in app.breakpoints:
              if bp.path == b.path and bp.enabled:
                lines.add(bp.line.toDAPLine())
            app.dapThread.requestSetBreakpoints(b.path, lines)
            app.dapThread.requestLaunch(b.path.changeFileExt(""), cwd = b.path.parentDir, stopOnEntry = false)
            app.dapThread.requestConfigurationDone()
      of dmkRunning:
        app.debugState = dssRunning
      of dmkError:
        app.debugState = dssError
        stderr.writeLine("[app] DAP error: " & resp.str1)
        discard app.notificationManager.error("DAP: " & resp.str1)
        if app.dapThread != nil:
          app.dapThread.shutdown()
          app.dapThread = nil
        app.debugStopThreadId = 0
      of dmkStopped:
        app.debugState = dssStopped
        app.debugStopThreadId = resp.int1
        stderr.writeLine("[app] DAP stopped: reason=" & resp.str1 & " threadId=" & $resp.int1)
        app.debugPanel.clearVariables()
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
        app.debugState = dssTerminated
        app.debugStopThreadId = 0
        app.debugPanel.addOutput("Debug session terminated")
        if app.dapThread != nil:
          app.dapThread.shutdown()
          app.dapThread = nil
      of dmkStackTraceResponse:
        let frames = parseStackFrames(resp.jsonData)
        app.debugPanel.frames = frames
        # Sync frames to debug sidebar
        app.debugSidebar.frames = frames
        # Auto-navigate to top frame
        if frames.len > 0 and frames[0].source.len > 0:
          let idx = app.openBuffer(frames[0].source)
          if idx >= 0 and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
            app.buffers[app.currentBuffer].ed.gotoLine(frames[0].line, frames[0].column)
        # Request scopes for the top stack frame so variables can be shown
        if frames.len > 0 and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
          app.dapThread.requestScopes(frames[0].id)
      of dmkScopesResponse:
        let scopes = parseScopes(resp.jsonData)
        app.debugPanel.clearVariables()
        app.debugPanel.addScopes(scopes)
        # Automatically expand scopes and request their variables
        for scopeNode in app.debugPanel.varNodes:
          scopeNode.expanded = true
          if scopeNode.variablesReference > 0 and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
            scopeNode.loading = true
            app.dapThread.requestVariables(scopeNode.variablesReference)
      of dmkVariablesResponse:
        let variables = parseVariables(resp.jsonData)
        app.debugPanel.addVariables(resp.int1, variables)
      of dmkSetVariableResponse:
        if resp.jsonData.hasKey("success") and not resp.jsonData["success"].getBool():
          let msg = if resp.jsonData.hasKey("message"): resp.jsonData["message"].getStr() else: "set variable failed"
          app.debugPanel.addOutput("Error: " & msg)
        else:
          # Refresh the parent scope so the new value is reflected.
          if app.dapThread != nil and app.dapThread.isReady.load(moAcquire) and resp.int1 > 0:
            app.dapThread.requestVariables(resp.int1)
      of dmkEvaluateResponse:
        if resp.jsonData.hasKey("success") and not resp.jsonData["success"].getBool():
          let msg = if resp.jsonData.hasKey("message"): resp.jsonData["message"].getStr() else: "evaluate failed"
          app.debugPanel.addOutput("Error: " & msg)
        elif resp.jsonData.hasKey("body"):
          let body = resp.jsonData["body"]
          let val = if body.hasKey("result"): body["result"].getStr() else: ""
          let typ = if body.hasKey("type"): body["type"].getStr() else: ""
          var line = val
          if typ.len > 0:
            line.add("  (")
            line.add(typ)
            line.add(")")
          app.debugPanel.addOutput(line)
        else:
          app.debugPanel.addOutput("evaluate returned empty response")
      else:
        discard
      # Sync debug panel state to sidebar
      app.debugSidebar.state = app.debugPanel.state

    # Poll AI responses
    while app.aiThread != nil:
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
        app.aiPanel.appendThinking(resp.text)
      of amkFileChanged:
        let path = resp.text
        stderr.writeLine("[app] AI changed file: " & path)
        for i, b in app.buffers:
          if b.path == path:
            if b.ed.changed:
              discard app.notificationManager.warning("AI modified " & extractFilename(path) & " 锟?reload skipped (unsaved changes)")
            else:
              try:
                app.buffers[i].ed.loadFromFile(path)
                app.buffers[i].lastSaveTick = getTicks()
                app.buffers[i].lastChanged = false
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
        app.aiPanel.isStreaming = false
        discard app.notificationManager.error("AI: " & resp.error)
        # Thread has exited or is unusable; clear it so the next send creates a fresh one.
        app.aiThread = nil
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

        # Auto-close pre-processing: intercept before SynEdit sees the event.
        if app.config.autoCloseBrackets and app.focus == "editor" and
           not app.buffers[idx].readOnly and not app.gi.isConsumed:
          let acEd = addr app.buffers[idx].ed
          if edEvent.kind == TextInputEvent:
            var text = ""
            for c in edEvent.text:
              if c == '\0': break
              text.add c
            if text.len == 1:
              let ch = text[0]
              if shouldSkipOver(acEd[], ch):
                # Already sitting on this closer 锟?advance cursor past it.
                acEd[].gotoPos(acEd[].cursor + 1)
                edEvent = default Event
              elif shouldAutoClose(acEd[], ch):
                let closing = pairClose(ch)
                if closing != '\0':
                  let insertPos = acEd[].cursor
                  acEd[].insertText($ch & $closing)
                  acEd[].gotoPos(insertPos + 1)
                  edEvent = default Event
          elif edEvent.kind == KeyDownEvent and edEvent.key == KeyBackspace and
               edEvent.mods == {}:
            if shouldDeletePair(acEd[]):
              # Delete both opener (before cursor) and closer (after cursor).
              let pos = acEd[].cursor
              var full = acEd[].fullText()
              if pos > 0 and pos < full.len:
                full = full[0 ..< pos - 1] & full[pos + 1 .. ^1]
                acEd[].setText(full)
                acEd[].gotoPos(pos - 1)
              edEvent = default Event

        let editorHovered = e.kind == MouseWheelEvent and editorBounds.contains(point(e.x, e.y))
        let edAct = app.buffers[idx].ed.draw(edEvent, editorBounds, app.focus == "editor" or editorHovered)
        case edAct.kind
        of ctrlHover:
          if e.kind == MouseMoveEvent and app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.buffers[idx].path.len > 0:
            let lang = languageIdFor(app.buffers[idx].path)
            if lang == app.lspLanguage and app.lspServerForLanguage(lang).len > 0:
              if edAct.pos != app.hoverPendingPos:
                app.hoverPendingPos = edAct.pos
                let (line, col) = bufferPosToLineCol(app.buffers[idx].ed.fullText(), edAct.pos)
                app.hoverPendingLine = line
                app.hoverPendingCol = col
                app.hoverPendingTick = getTicks() + 400
                stderr.writeLine("[app] ctrlHover pending: pos=" & $edAct.pos & " line=" & $line & " col=" & $col)
        of ctrlClick:
          if app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.buffers[idx].path.len > 0:
            let lang = languageIdFor(app.buffers[idx].path)
            if lang == app.lspLanguage and app.lspServerForLanguage(lang).len > 0:
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

        # Sync dirty state for tab modified indicator and title bar
        if app.buffers[idx].ed.changed != app.buffers[idx].lastChanged:
          app.buffers[idx].lastChanged = app.buffers[idx].ed.changed
          app.tabBar.updateTabModified($idx, app.buffers[idx].ed.changed)
          if idx == app.currentBuffer:
            app.updateTitle()
            app.updateStatus()
        if app.buffers[idx].ed.changed:
          app.buffers[idx].lastEditTick = getTicks()

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

          # Redraw the scrollbar grip on top so the handle stays visible above
          # the git diff colors. Geometry mirrors SynEdit.scrollGrip.
          let lineH = fontLineSkip(app.font)
          let contentH = float(totalLines * lineH)
          let gripTrackH = float(editorBounds.h - 2)
          let ratio = float(editorBounds.h) / contentH
          let gripH = clamp(int(gripTrackH * ratio), 20, int(gripTrackH))
          let scrollArea = gripTrackH - float(gripH)
          let maxScroll = float(totalLines - ed.span)
          let posRatio = if maxScroll > 0: float(ed.firstLine) / maxScroll else: 0.0
          let gripY = clamp(int(scrollArea * posRatio) + editorBounds.y + 1,
                            editorBounds.y + 1, editorBounds.y + editorBounds.h - gripH - 1)
          let gripRect = rect(trackX, gripY, ScrollBarWidth - 2, gripH)
          fillRect(gripRect, currentTheme.getColor(tcTextSecondary))
    else:
      if app.screen == asWorkspace:
        discard drawText(app.font, editorBounds.x + 12, editorBounds.y + 12,
                         "No file open", color(150, 150, 150), color(0, 0, 0, 0))

    # Delayed hover trigger
    if app.lspThread != nil and app.lspThread.isReady.load(moAcquire) and app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len and app.buffers[app.currentBuffer].path.len > 0 and
       getTicks() >= app.hoverPendingTick:
      let idx = app.currentBuffer
      let lang = languageIdFor(app.buffers[idx].path)
      if lang == app.lspLanguage and app.lspServerForLanguage(lang).len > 0:
        stderr.writeLine("[app] hover trigger fired: pos=" & $app.hoverPendingPos & " line=" & $app.hoverPendingLine & " col=" & $app.hoverPendingCol & " mouse=(" & $app.mouseX & "," & $app.mouseY & ")")
        app.lspThread.cancelHover()
        inc app.hoverNextRequestId
        app.lspThread.requestHover(app.buffers[idx].path, app.hoverPendingLine, app.hoverPendingCol, app.hoverNextRequestId)
        app.hoverRequestId = app.hoverNextRequestId
        app.hoverRequestPos = app.hoverPendingPos
        app.hoverRequestPath = app.buffers[idx].path
        app.hoverMouseX = app.mouseX
        app.hoverMouseY = app.mouseY
      else:
        app.clearPendingHover()
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
                       "脳", currentTheme.getColor(tcTextSecondary), color(0, 0, 0, 0))
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
    app.modelSelectDialog.render(app.width, app.height)
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

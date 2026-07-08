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
  if name.len == 0 or app.config.themeName == name:
    return
  app.setTheme(name)
  app.config.themeName = name
  saveAppConfig(app)

type AgentDef* = object
  id*: string
  label*: string

const CommonAgents* = [
  AgentDef(id: "kimi", label: "Kimi"),
  AgentDef(id: "claude", label: "Claude Code"),
  AgentDef(id: "opencode", label: "OpenCode"),
  AgentDef(id: "gemini", label: "Gemini"),
  AgentDef(id: "codex", label: "Codex"),
  AgentDef(id: "cursor", label: "Cursor"),
  AgentDef(id: "builtin", label: "Built-in"),
  AgentDef(id: "custom", label: "Custom"),
]

proc agentLabel(agentId: string): string =
  if agentId.len == 0:
    return "Kimi"
  for a in CommonAgents:
    if a.id == agentId:
      return a.label
  return agentId.capitalizeAscii()

proc aiSubtitle(config: cfg.AppConfig): string =
  let agent = agentLabel(config.aiAgent)
  if config.aiAgent.toLowerAscii() == "builtin":
    let (providerId, model) = cfg.effectiveBuiltinModel(config)
    if model.len > 0:
      return agent & " — " & providerLabel(providerId) & " / " & model
    return agent
  let detected = detectAIModel(config.aiAgent, getCurrentDir())
  let model = if detected.len > 0: detected else: config.aiModel
  if model.len > 0:
    return agent & " — " & model
  return agent

proc refreshThinkingControls(app: App) =
  ## Show the reasoning-effort variants button only for a thinking-capable
  ## builtin provider, and keep its label in sync with the configured effort.
  ## Clamps the effort to the current provider's variant set, since variants are
  ## provider-specific (e.g. DeepSeek high/max vs OpenAI minimal/low/medium/high).
  let (providerId, _) = cfg.effectiveBuiltinModel(app.config)
  let variants = reasoningVariants(providerId)
  if variants.len > 0 and app.config.aiReasoningEffort notin variants:
    app.config.aiReasoningEffort = variants[0]
  app.aiPanel.showVariants =
    isHttpAgent(app.config.aiAgent) and providerSupportsThinking(providerId)
  app.aiPanel.reasoningEffort = app.config.aiReasoningEffort

proc restartAiThreadIfRunning(app: App) =
  if app.aiThread != nil:
    app.aiThread.shutdown()
    app.aiThread = nil
    app.aiPanel.clearChat()
    try:
      app.aiThread = newAIThread(app.config)
    except CatchableError as e:
      stderr.writeLine("[app] Failed to restart AI thread: " & e.msg)
      discard app.notificationManager.error("Failed to restart AI: " & e.msg)

proc promptApiKey(app: App, onConfirmed: proc() = nil) =
  app.inputDialog.title = "API Key"
  let (providerId, _) = cfg.effectiveBuiltinModel(app.config)
  app.inputDialog.prompt = "Enter API key for " & providerLabel(providerId) & ":"
  app.inputDialog.text = app.config.aiApiKey
  app.inputDialog.centerOnScreen(app.width, app.height)
  app.inputDialog.onResult = proc(confirmed: bool, text: string) =
    if confirmed:
      app.config.aiApiKey = text
      saveAppConfig(app)
      if onConfirmed != nil:
        onConfirmed()
  app.inputDialog.show()

proc ensureBuiltinApiKey(app: App, onReady: proc() = nil) =
  if not isHttpAgent(app.config.aiAgent) or app.config.aiApiKey.len > 0:
    if onReady != nil:
      onReady()
    return
  if app.inputDialog.isVisible:
    return
  app.promptApiKey(proc() =
    if onReady != nil:
      onReady()
  )

proc applyAgent(app: App, agentId: string) =
  ## Apply an agent switch, persist it as the new default, and restart the AI thread.
  stderr.writeLine("[app] switching AI agent to: " & agentId)
  app.config.aiAgent = agentId
  app.initialAiAgent = agentId
  saveAppConfig(app)
  if app.aiThread != nil:
    app.aiThread.shutdown()
    app.aiThread = nil
  app.aiPanel.clearChat()
  app.aiPanel.placeholder = "Ask " & agentLabel(agentId) & "..."
  app.aiPanel.subtitle = aiSubtitle(app.config)
  app.aiPanel.showModelControls = isHttpAgent(agentId)
  app.refreshThinkingControls()
  app.ensureBuiltinApiKey(proc() =
    try:
      app.aiThread = newAIThread(app.config)
    except CatchableError as e:
      stderr.writeLine("[app] Failed to start AI thread: " & e.msg)
      discard app.notificationManager.error("Failed to start AI: " & e.msg)
  )

proc selectAgent(app: App, agentId: string)

proc makeSelectAgentAction(app: App, agentId: string): proc() =
  ## Factory to avoid Nim's loop-variable closure capture bug.
  result = proc() = app.selectAgent(agentId)

proc selectAgent(app: App, agentId: string) =
  ## Switch the active AI provider and start a fresh chat session.
  if app.config.aiAgent == agentId:
    app.aiPanel.clearChat()
    if app.aiPanel.onNewSession != nil:
      app.aiPanel.onNewSession()
    return
  if agentId == "custom" and app.config.aiCommand.len == 0:
    app.inputDialog.title = "Custom AI Command"
    app.inputDialog.prompt = "Enter ACP command (e.g. /path/to/agent acp):"
    app.inputDialog.text = ""
    app.inputDialog.centerOnScreen(app.width, app.height)
    app.inputDialog.onResult = proc(confirmed: bool, text: string) =
      if confirmed and text.len > 0:
        app.config.aiCommand = text
        saveAppConfig(app)
        app.applyAgent(agentId)
    app.inputDialog.show()
    return
  app.applyAgent(agentId)

proc selectModelForPreset(app: App, preset, providerId, model: string) =
  ## Set the provider/model for a specific lightweight/heavyweight/auto preset.
  let p = preset.toLowerAscii()
  case p
  of "auto":
    app.config.aiBuiltinModelProvider = providerId
    app.config.aiBuiltinModel = model
  of "heavyweight":
    app.config.aiHeavyweightModelProvider = providerId
    app.config.aiHeavyweightModel = model
  else:
    app.config.aiLightweightModelProvider = providerId
    app.config.aiLightweightModel = model
  # Model selection does not change a configured base URL. Only fill in the
  # default when the user hasn't set one yet.
  if app.config.aiBaseUrl.len == 0:
    app.config.aiBaseUrl = defaultBaseUrl(providerId)
  app.aiPanel.subtitle = aiSubtitle(app.config)
  app.refreshThinkingControls()
  saveAppConfig(app)
  # Only restart the thread if the changed preset is currently active.
  if isHttpAgent(app.config.aiAgent) and app.config.aiModelPreset.toLowerAscii() == p:
    app.ensureBuiltinApiKey(proc() = app.restartAiThreadIfRunning())

proc selectPreset(app: App, preset: string) =
  ## Switch the lightweight/heavyweight/auto preset at runtime. Not persisted.
  app.config.aiModelPreset = preset
  app.aiPanel.modelPreset = preset
  app.aiPanel.subtitle = aiSubtitle(app.config)
  app.refreshThinkingControls()
  if isHttpAgent(app.config.aiAgent):
    app.ensureBuiltinApiKey(proc() = app.restartAiThreadIfRunning())

proc setReasoningEffort(app: App, effort: string) =
  ## Set the thinking-mode reasoning-effort variant and apply it to the running
  ## session. Consistent with model/preset changes, this restarts the thread so
  ## subsequent turns use the new effort.
  app.config.aiReasoningEffort = effort
  app.aiPanel.reasoningEffort = effort
  saveAppConfig(app)
  if isHttpAgent(app.config.aiAgent):
    app.ensureBuiltinApiKey(proc() = app.restartAiThreadIfRunning())

proc makeSelectEffortAction(app: App, effort: string): proc() =
  ## Factory to avoid Nim's loop-variable closure capture bug.
  result = proc() = app.setReasoningEffort(effort)

proc showModelActionMenu(app: App, providerId, model: string)

proc showUnifiedModelDialog(app: App) =
  ## Show the unified model/preset picker dialog.
  app.modelSelectDialog.title = "Model"
  app.modelSelectDialog.lightProvider = app.config.aiLightweightModelProvider
  app.modelSelectDialog.lightModel = app.config.aiLightweightModel
  app.modelSelectDialog.heavyProvider = app.config.aiHeavyweightModelProvider
  app.modelSelectDialog.heavyModel = app.config.aiHeavyweightModel
  app.modelSelectDialog.enabledModels = app.config.aiEnabledModels
  app.modelSelectDialog.setModels(allBuiltinModels(app.config))
  app.modelSelectDialog.centerOnScreen(app.width, app.height)
  app.modelSelectDialog.onSelectAuto = proc() =
    app.selectPreset("auto")
  app.modelSelectDialog.onSelectModel = proc(providerId, model: string) =
    app.showModelActionMenu(providerId, model)
  app.modelSelectDialog.onToggleModel = proc(providerId, model: string, enabled: bool) =
    let key = providerId & "/" & model
    let idx = app.config.aiEnabledModels.find(key)
    if enabled:
      if idx < 0:
        app.config.aiEnabledModels.add(key)
    else:
      if idx >= 0:
        app.config.aiEnabledModels.del(idx)
    app.aiPanel.subtitle = aiSubtitle(app.config)
    saveAppConfig(app)
    # Refresh the dialog to show updated disabled state.
    app.modelSelectDialog.enabledModels = app.config.aiEnabledModels
  app.modelSelectDialog.show()
  discard app.gi.consume()

proc showModelActionMenu(app: App, providerId, model: string) =
  ## Show the action menu for a selected model.
  app.contextMenu.clear()
  let key = providerId & "/" & model
  let isEnabled = app.config.aiEnabledModels.len == 0 or key in app.config.aiEnabledModels
  if isEnabled:
    app.contextMenu.addItem("set-light", "Set as Light Model", proc() =
      app.selectModelForPreset("lightweight", providerId, model)
      app.selectPreset("lightweight"))
    app.contextMenu.addItem("set-heavy", "Set as Heavy Model", proc() =
      app.selectModelForPreset("heavyweight", providerId, model)
      app.selectPreset("heavyweight"))
    app.contextMenu.addSeparator()
    app.contextMenu.addItem("set-apikey", "Set API Key", proc() =
      app.config.aiBuiltinModelProvider = providerId
      app.config.aiBuiltinModel = model
      app.promptApiKey())
    app.contextMenu.addSeparator()
    app.contextMenu.addItem("disable", "Disable Model", proc() =
      app.modelSelectDialog.onToggleModel(providerId, model, false))
  else:
    app.contextMenu.addItem("enable", "Enable Model", proc() =
      app.modelSelectDialog.onToggleModel(providerId, model, true))
  app.contextMenu.showAt(app.width div 2, app.height div 2, app.width, app.height)
  discard app.gi.consume()

proc promptBaseUrl(app: App) =
  app.inputDialog.title = "Base URL"
  app.inputDialog.prompt = "Enter base URL (empty = default):"
  let (providerId, _) = cfg.effectiveBuiltinModel(app.config)
  app.inputDialog.text = if app.config.aiBaseUrl.len > 0: app.config.aiBaseUrl else: defaultBaseUrl(providerId)
  app.inputDialog.centerOnScreen(app.width, app.height)
  app.inputDialog.onResult = proc(confirmed: bool, text: string) =
    if confirmed:
      app.config.aiBaseUrl = text
      saveAppConfig(app)
  app.inputDialog.show()

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
    let (providerId, _) = cfg.effectiveBuiltinModel(app.config)
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

proc languageIdFor(path: string): string =
  ## Map a file path to an LSP language identifier based on its extension.
  if path.len == 0:
    return "nim"
  let ext = path.splitFile.ext.toLowerAscii()
  case ext
  of ".nim", ".nims": "nim"
  of ".py": "python"
  of ".js", ".jsx": "javascript"
  of ".ts", ".tsx": "typescript"
  of ".c", ".h": "c"
  of ".cpp", ".cc", ".cxx", ".hpp": "cpp"
  of ".cs": "csharp"
  of ".java": "java"
  of ".rs": "rust"
  of ".html", ".htm": "html"
  of ".xml": "xml"
  of ".md", ".markdown": "markdown"
  else: ""

proc lspServerForLanguage(app: App, lang: string): string =
  ## Resolve the configured LSP server for a language, falling back to the
  ## legacy single `lspServer` value for Nim or when the per-language table
  ## is empty.
  if lang.len == 0:
    return ""
  if app.config.lspServers.hasKey(lang):
    return app.config.lspServers[lang]
  if lang == "nim" and app.config.lspServer.len > 0:
    return app.config.lspServer
  return ""

proc lspStatusString(app: App): string =
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    return "LSP: " & app.lspServer
  elif app.lspStarting:
    return "LSP: starting..."
  else:
    return "LSP: off"

proc lspStatusTooltip(app: App): string =
  ## Detailed tooltip shown when hovering the status-bar LSP section.
  let state = if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    "ready"
  elif app.lspStarting:
    "starting"
  elif app.lspThread != nil:
    "error"
  else:
    "off"
  result = "Server: " & app.lspServer & "\nLanguage: " & app.lspLanguage & "\nState: " & state
  if app.lspErrorMsg.len > 0:
    result.add("\nError: " & app.lspErrorMsg)

proc applyLspEditsToBuffer(app: App, idx: int, edits: seq[LSPTextEdit]) =
  ## Apply a sequence of LSP text edits to an open buffer and notify the LSP server.
  if idx < 0 or idx >= app.buffers.len or edits.len == 0:
    return
  let b = addr app.buffers[idx]
  let newText = applyTextEdits(b.ed.fullText, edits)
  b.ed.setText(newText)
  b.ed.markChanged()
  b.lastChanged = true
  app.tabBar.updateTabModified($idx, true)
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    app.lspThread.notifyDidChange(b.path, newText)

proc lspRangeForSelection(ed: SynEdit): Option[LSPRange] =
  ## Derive an LSP range from the current editor selection.
  ## SynEdit does not expose selection offsets, so we locate the selected text
  ## in the full buffer and pick the occurrence closest to the cursor.
  let selected = ed.getSelectedText()
  if selected.len == 0:
    return none(LSPRange)
  let full = ed.fullText()
  let cursorOff = offsetAtLineCol(full, ed.currentLine, ed.currentCol)
  var bestStart = -1
  var bestDist = high(int)
  var start = 0
  while start <= full.len - selected.len:
    let idx = find(full, selected, start)
    if idx < 0:
      break
    let endOff = idx + selected.len
    let dist = if cursorOff >= idx and cursorOff <= endOff:
      0
    else:
      min(abs(cursorOff - idx), abs(cursorOff - endOff))
    if dist < bestDist:
      bestDist = dist
      bestStart = idx
      if dist == 0:
        break
    start = idx + 1
  if bestStart < 0:
    return none(LSPRange)
  let (startLine, startCol) = lineColAtOffset(full, bestStart)
  let (endLine, endCol) = lineColAtOffset(full, bestStart + selected.len)
  return some(LSPRange(
    start: LSPPosition(line: startLine, character: startCol),
    `end`: LSPPosition(line: endLine, character: endCol)
  ))

proc dapStatusString(app: App): string =
  case app.debugState
  of dssOff: "DBG: off"
  of dssStarting: "DBG: starting..."
  of dssReady: "DBG: ready"
  of dssRunning: "DBG: running"
  of dssStopped: "DBG: stopped"
  of dssError: "DBG: error"
  of dssTerminated: "DBG: terminated"

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
      app.statusBar.lineEndingIndex = -1
      app.statusBar.encodingIndex = -1
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
      app.statusBar.encodingIndex = 1
      app.statusBar.lineEndingIndex = 2

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

proc pushClipboardHistory*(app: App, text: string) =
  ## Add text to the clipboard ring, removing duplicates and capping at config size.
  if text.len == 0 or app.config.clipboardHistorySize <= 0:
    return
  let idx = app.clipboardHistory.find(text)
  if idx >= 0:
    app.clipboardHistory.delete(idx)
  app.clipboardHistory.insert(text, 0)
  if app.clipboardHistory.len > app.config.clipboardHistorySize:
    app.clipboardHistory.setLen(app.config.clipboardHistorySize)

proc saveBuffer(app: App, idx: int; silent: bool = false): bool =
  ## Save a specific buffer by index. Returns true on success.
  if idx < 0 or idx >= app.buffers.len:
    return false
  let b = app.buffers[idx]
  if b.path.len == 0:
    return false
  if b.isImage:
    if not silent:
      discard app.notificationManager.info("Images are read-only")
    return false
  try:
    app.buffers[idx].ed.saveToFile(b.path)
  except CatchableError as err:
    if not silent:
      discard app.notificationManager.error("Failed to save " & b.path.extractFilename & ": " & err.msg)
    return false
  if not silent:
    discard app.notificationManager.success("Saved " & b.path.extractFilename)
  app.lastDiffLines[idx] = getDiffLines(b.path)
  app.buffers[idx].lastSaveTick = getTicks()
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    let lang = languageIdFor(b.path)
    if app.lspServerForLanguage(lang).len > 0:
      let text = app.buffers[idx].ed.fullText()
      app.lspThread.notifyDidChange(b.path, text)
  return true

proc checkAutoSave(app: App) =
  ## Save dirty buffers after the configured auto-save delay.
  if app.config.autoSave != "afterDelay":
    return
  let now = getTicks()
  for i in 0 ..< app.buffers.len:
    let b = app.buffers[i]
    if b.path.len == 0 or b.isImage or b.diffPath.len > 0:
      continue
    if not b.ed.changed:
      continue
    if b.lastSaveTick >= b.lastEditTick:
      continue
    if now - b.lastEditTick > app.config.autoSaveDelayMs:
      discard app.saveBuffer(i, silent = true)

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

  discard app.notificationManager.info("Requesting AI review of " & $allFiles.len & " changed file(s)...")

  app.aiPanelVisible = true
  if app.aiThread == nil:
    app.aiThread = newAIThread(app.config)
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
  let lang = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
               languageIdFor(app.buffers[app.currentBuffer].path)
             else:
               "nim"
  app.lspLanguage = lang
  app.lspServer = serverName
  app.config.lspServers[lang] = serverName
  if lang == "nim":
    app.config.lspServer = serverName
  saveAppConfig(app)
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
  # Restart if any buffer of this language is open
  var hasLang = false
  for b in app.buffers:
    if languageIdFor(b.path) == lang:
      hasLang = true
      break
  if hasLang:
    app.lspThread = newLSPThread(lspExeFor(app.lspServer), lang, app.config.lspConfig)
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
    let prefix = if b.ed.changed: "• " else: ""
    setWindowTitle(prefix & name & " - Drift")
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

  # Remember closed tab so it can be reopened.
  let b = app.buffers[idx]
  if b.path.len > 0 and app.config.closedTabHistorySize > 0:
    app.closedTabs.add(ClosedTabInfo(path: b.path, line: b.ed.currentLine, col: b.ed.currentCol))
    if app.closedTabs.len > app.config.closedTabHistorySize:
      app.closedTabs.delete(0)

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
  var ed = createSynEdit(app.font, app.editorTheme())
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
  app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)

proc addRecentFolder*(app: App, path: string) =
  app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = true)
  saveRecentFiles(app.recentFiles)
  app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)

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
    var ed = createSynEdit(app.font, app.editorTheme())
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
    app.buffers[result].lastSaveTick = getTicks()
    return result

  var ed = createSynEdit(app.font, app.editorTheme())
  ed.showLineNumbers = app.config.showLineNumbers
  ed.lang = fileExtToLanguage(path.splitFile.ext)
  ed.tabSize = app.config.tabSize
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
  app.buffers[result].lastSaveTick = getTicks()

  # Start LSP for supported languages
  let lang = languageIdFor(path)
  let server = app.lspServerForLanguage(lang)
  if server.len > 0:
    if app.lspThread.isNil and not app.lspStarting:
      stderr.writeLine("[app] starting LSP thread: " & lspExeFor(server) & " language: " & lang)
      app.lspServer = server
      app.lspLanguage = lang
      app.lspThread = newLSPThread(lspExeFor(server), lang, app.config.lspConfig)
      app.lspStarting = true
    elif app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
      app.lspThread.notifyDidOpen(path, ed.fullText())

proc newBuffer(app: App) =
  var ed = createSynEdit(app.font, app.editorTheme())
  ed.showLineNumbers = app.config.showLineNumbers
  ed.lang = langNim
  ed.tabSize = app.config.tabSize
  app.buffers.add(Buffer(ed: ed, path: "", isImage: false))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  let idx = app.buffers.high
  discard app.tabBar.addTab($idx, "untitled")
  app.switchBuffer(idx)
  app.buffers[idx].lastSaveTick = getTicks()

proc newFile*(app: App)
proc openFolder*(app: App, path: string)

proc saveCurrentBuffer(app: App): bool =
  saveBuffer(app, app.currentBuffer)

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
  app.buffers[app.currentBuffer].lastSaveTick = getTicks()
  app.updateTitle()
  app.updateStatus()
  app.tabBar.clearTabs()
  for i, b in app.buffers:
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    discard app.tabBar.addTab($i, name)
  discard app.tabBar.setActiveTab($app.currentBuffer)
  # Notify LSP about the new file path
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    let lang = languageIdFor(path)
    if app.lspServerForLanguage(lang).len > 0:
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
      app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)
      return true
  false

# Public API

proc continueDebugging*(app: App) =
  if not app.debugState.canContinue: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestContinue(app.debugStopThreadId)

proc startDebugging*(app: App) =
  if not app.debugState.canStart:
    discard app.notificationManager.warning("A debug session is already active")
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
  app.debugState = dssStarting
  app.debugStopThreadId = 0
  app.debugPanel.clear()
  app.showTerminal = true
  app.bottomPanelTab = "debug"
  discard app.notificationManager.info("Debug session started")

proc startOrContinueDebugging*(app: App) =
  if app.debugState.canContinue:
    app.continueDebugging()
  else:
    app.startDebugging()

proc stopDebugging*(app: App) =
  if not app.debugState.canStop: return
  if app.dapThread != nil:
    app.dapThread.requestDisconnect()
    app.dapThread.shutdown()
    app.dapThread = nil
  app.debugState = dssOff
  app.debugStopThreadId = 0
  discard app.notificationManager.info("Debug session stopped")

proc stepOverDebugging*(app: App) =
  if not app.debugState.canStep: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestNext(app.debugStopThreadId)

proc stepIntoDebugging*(app: App) =
  if not app.debugState.canStep: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestStepIn(app.debugStopThreadId)

proc stepOutDebugging*(app: App) =
  if not app.debugState.canStep: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestStepOut(app.debugStopThreadId)

proc toggleBreakpoint*(app: App) =
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len: return
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
  if app.debugState.isActive and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    var lines: seq[int] = @[]
    for bp in app.breakpoints:
      if bp.path == b.path and bp.enabled:
        lines.add(bp.line.toDAPLine())
    app.dapThread.requestSetBreakpoints(b.path, lines)

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
  app.debugPanel.onVariablesRequest = proc(variablesReference: int) =
    if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
      app.dapThread.requestVariables(variablesReference)

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
      app.inputDialog.show())
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
  app.commandPalette.registerCommand("theme.selector", "Color Theme", "Open theme selector", ccView, "",
    proc() =
      app.themeSelector.show(app.config.themeName))

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
      app.lspThread.requestDocumentSymbols(b.path))

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
        elif idx == app.statusBar.encodingIndex:
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
                  discard app.notificationManager.warning("File changed externally: " & path.extractFilename & " — reload skipped (unsaved changes)")
              break
        if path.dirExists or (path.parentDir.dirExists):
          app.fileExplorer.refresh()
      of feDeleted:
        let dirPath = path.parentDir
        if dirPath.dirExists:
          app.fileExplorer.refresh()

    # Auto-save dirty buffers after delay
    app.checkAutoSave()

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
              discard app.notificationManager.warning("AI modified " & extractFilename(path) & " — reload skipped (unsaved changes)")
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
                # Already sitting on this closer — advance cursor past it.
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

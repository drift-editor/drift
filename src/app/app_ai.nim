## AI agent, model/preset, and settings (SettingItem) procs.
##
## This file is `include`d into app.nim (after the `App` type is defined) so the
## `proc`s below can reference `App` directly without a circular import.

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
    let (providerId, model) = cfg.effectiveModel(config)
    if model.len > 0:
      return agent & " 鈥?" & providerLabel(providerId) & " / " & model
    return agent
  let detected = detectAIModel(config.aiAgent, getCurrentDir())
  let model = if detected.len > 0: detected else: config.aiModel
  if model.len > 0:
    return agent & " 鈥?" & model
  return agent

proc refreshThinkingControls(app: App) =
  ## Show the reasoning-effort variants button only for a thinking-capable
  ## builtin provider, and keep its label in sync with the configured effort.
  ## Clamps the effort to the current provider's variant set, since variants are
  ## provider-specific (e.g. DeepSeek high/max vs OpenAI minimal/low/medium/high).
  let (providerId, _) = cfg.effectiveModel(app.config)
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
  let (providerId, _) = cfg.effectiveModel(app.config)
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
  let (providerId, _) = cfg.effectiveModel(app.config)
  app.inputDialog.text = if app.config.aiBaseUrl.len > 0: app.config.aiBaseUrl else: defaultBaseUrl(providerId)
  app.inputDialog.centerOnScreen(app.width, app.height)
  app.inputDialog.onResult = proc(confirmed: bool, text: string) =
    if confirmed:
      app.config.aiBaseUrl = text
      saveAppConfig(app)
  app.inputDialog.show()

proc buildSettingsItems*(app: App): seq[SettingItem] =
  ## Build the searchable list of editable settings shown by the settings picker.
  result.add(SettingItem(
    key: "editor.tabSize",
    label: "Tab Size",
    description: "Number of spaces per indentation level",
    kind: skInt,
    getValue: proc(): string = $app.config.tabSize,
    setValue: proc(value: string) =
      try:
        let n = parseInt(value)
        if n >= 1 and n <= 8:
          app.config.tabSize = n
          for i in 0 ..< app.buffers.len:
            if not app.buffers[i].isImage:
              app.buffers[i].ed.tabSize = n
          saveAppConfig(app)
          discard app.notificationManager.info("Tab size: " & $n)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "editor.showLineNumbers",
    label: "Show Line Numbers",
    description: "Display line numbers in the editor gutter",
    kind: skBool,
    getValue: proc(): string = $app.config.showLineNumbers,
    setValue: proc(value: string) =
      try:
        app.config.showLineNumbers = parseBool(value)
        for i in 0 ..< app.buffers.len:
          if not app.buffers[i].isImage:
            app.buffers[i].ed.showLineNumbers = app.config.showLineNumbers
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "editor.autoIndent",
    label: "Auto Indent",
    description: "Smart indent on Enter",
    kind: skBool,
    getValue: proc(): string = $app.config.autoIndent,
    setValue: proc(value: string) =
      try:
        app.config.autoIndent = parseBool(value)
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "editor.autoCloseBrackets",
    label: "Auto Close Brackets",
    description: "Auto-insert closing brackets and quotes",
    kind: skBool,
    getValue: proc(): string = $app.config.autoCloseBrackets,
    setValue: proc(value: string) =
      try:
        app.config.autoCloseBrackets = parseBool(value)
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "editor.bracketHighlight",
    label: "Bracket Highlight",
    description: "Highlight matching bracket pairs",
    kind: skBool,
    getValue: proc(): string = $app.config.bracketHighlight,
    setValue: proc(value: string) =
      try:
        app.config.bracketHighlight = parseBool(value)
        for i in 0 ..< app.buffers.len:
          if not app.buffers[i].isImage:
            app.buffers[i].ed.theme = app.editorTheme()
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "workbench.theme",
    label: "Color Theme",
    description: "Current color theme (use Color Theme command to change)",
    kind: skSpecial,
    getValue: proc(): string = app.config.theme,
    setValue: proc(value: string) = discard
  ))
  result.add(SettingItem(
    key: "search.caseSensitive",
    label: "Search Case Sensitive",
    description: "Default case-sensitive search",
    kind: skBool,
    getValue: proc(): string = $app.config.searchCaseSensitive,
    setValue: proc(value: string) =
      try:
        app.config.searchCaseSensitive = parseBool(value)
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "search.useRegex",
    label: "Search Use Regex",
    description: "Default regex search",
    kind: skBool,
    getValue: proc(): string = $app.config.searchUseRegex,
    setValue: proc(value: string) =
      try:
        app.config.searchUseRegex = parseBool(value)
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "search.wholeWord",
    label: "Search Whole Word",
    description: "Default whole-word search",
    kind: skBool,
    getValue: proc(): string = $app.config.searchWholeWord,
    setValue: proc(value: string) =
      try:
        app.config.searchWholeWord = parseBool(value)
        saveAppConfig(app)
      except ValueError:
        discard
  ))
  result.add(SettingItem(
    key: "files.autoSave",
    label: "Auto Save",
    description: "off / afterDelay",
    kind: skString,
    getValue: proc(): string = app.config.autoSave,
    setValue: proc(value: string) =
      app.config.autoSave = value
      saveAppConfig(app)
  ))
  result.add(SettingItem(
    key: "files.autoSaveDelayMs",
    label: "Auto Save Delay",
    description: "Milliseconds before auto-saving",
    kind: skInt,
    getValue: proc(): string = $app.config.autoSaveDelayMs,
    setValue: proc(value: string) =
      try:
        let n = parseInt(value)
        if n >= 100:
          app.config.autoSaveDelayMs = n
          saveAppConfig(app)
      except ValueError:
        discard
  ))

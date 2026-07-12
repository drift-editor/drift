## Configuration loader
## Loads user settings from ~/.config/drift/config.json

import std/[os, json, strutils, tables]

type
  AppConfig* = object
    windowWidth*: int
    windowHeight*: int
    windowTitle*: string
    themeName*: string
    # Editor settings
    tabSize*: int
    autoIndent*: bool
    bracketHighlight*: bool
    autoCloseBrackets*: bool
    showLineNumbers*: bool
    lspServer*: string
    lspServers*: Table[string, string]  # Per-language LSP server executables
    lspConfig*: JsonNode  # Server-specific LSP configuration
    dapServer*: string
    dapConfig*: JsonNode  # Server-specific DAP configuration
    aiEnabled*: bool
    aiAgent*: string
    aiApiKey*: string
    aiModel*: string
    aiBaseUrl*: string
    aiCommand*: string
    aiModelPreset*: string
    aiBuiltinModelProvider*: string
    aiBuiltinModel*: string
    aiLightweightModelProvider*: string
    aiLightweightModel*: string
    aiHeavyweightModelProvider*: string
    aiHeavyweightModel*: string
    aiEnabledModels*: seq[string]  # Empty = all enabled; format "providerId/model"
    aiReasoningEffort*: string  # Thinking-mode effort variant for capable providers: "high" (default) or "max"
    # Phase 1: editor fit-and-finish
    autoSave*: string
    autoSaveDelayMs*: int
    fileWatcherAutoReload*: bool
    closedTabHistorySize*: int
    clipboardHistorySize*: int
    pinnedRecentFiles*: seq[string]
    searchCaseSensitive*: bool
    searchUseRegex*: bool
    searchWholeWord*: bool
    searchRememberOptions*: bool
    searchHistory*: seq[string]

  SettingKind* = enum
    skBool
    skInt
    skString
    skSpecial

  SettingItem* = object
    key*: string
    label*: string
    description*: string
    kind*: SettingKind
    getValue*: proc(): string {.closure.}
    setValue*: proc(value: string) {.closure.}

proc configDir*(): string =
  getConfigDir() / "drift"

proc configPath*(): string =
  configDir() / "config.json"

proc defaultConfig*(): AppConfig =
  AppConfig(
    windowWidth: 1200,
    windowHeight: 800,
    windowTitle: "Drift",
    themeName: "dark",
    tabSize: 2,
    autoIndent: true,
    bracketHighlight: true,
    autoCloseBrackets: true,
    showLineNumbers: true,
    lspServer: "minlsp",
    lspServers: {"nim": "minlsp"}.toTable(),
    lspConfig: newJObject(),
    dapServer: "nim_debug_adapter",
    dapConfig: newJObject(),
    aiEnabled: true,
    aiAgent: "builtin",
    aiModel: "kimi-for-coding",
    aiCommand: "",
    aiModelPreset: "lightweight",
    aiBuiltinModelProvider: "deepseek",
    aiBuiltinModel: "deepseek-v4-flash",
    aiLightweightModelProvider: "deepseek",
    aiLightweightModel: "deepseek-v4-flash",
    aiHeavyweightModelProvider: "deepseek",
    aiHeavyweightModel: "deepseek-v4-pro",
    aiReasoningEffort: "high",
    autoSave: "off",
    autoSaveDelayMs: 1000,
    fileWatcherAutoReload: true,
    closedTabHistorySize: 20,
    clipboardHistorySize: 10,
    pinnedRecentFiles: @[],
    searchCaseSensitive: false,
    searchUseRegex: false,
    searchWholeWord: false,
    searchRememberOptions: true,
    searchHistory: @[]
  )

proc loadConfig*(): AppConfig =
  result = defaultConfig()
  let path = configPath()
  if not fileExists(path):
    return result
  try:
    let data = readFile(path)
    let j = parseJson(data)
    if j.hasKey("windowWidth"):
      result.windowWidth = j["windowWidth"].getInt()
    if j.hasKey("windowHeight"):
      result.windowHeight = j["windowHeight"].getInt()
    if j.hasKey("windowTitle"):
      result.windowTitle = j["windowTitle"].getStr()
    if j.hasKey("theme"):
      result.themeName = j["theme"].getStr()
    if j.hasKey("tabSize"):
      let ts = j["tabSize"].getInt()
      if ts >= 1 and ts <= 8: result.tabSize = ts
    if j.hasKey("autoIndent"):
      result.autoIndent = j["autoIndent"].getBool()
    if j.hasKey("bracketHighlight"):
      result.bracketHighlight = j["bracketHighlight"].getBool()
    if j.hasKey("autoCloseBrackets"):
      result.autoCloseBrackets = j["autoCloseBrackets"].getBool()
    if j.hasKey("showLineNumbers"):
      result.showLineNumbers = j["showLineNumbers"].getBool()
    if j.hasKey("lspServer"):
      result.lspServer = j["lspServer"].getStr()
    if j.hasKey("lspServers") and j["lspServers"].kind == JObject:
      result.lspServers = initTable[string, string]()
      for key, val in j["lspServers"]:
        if val.kind == JString:
          result.lspServers[key] = val.getStr()
    if j.hasKey("lspConfig"):
      result.lspConfig = j["lspConfig"]
    else:
      result.lspConfig = newJObject()
    if j.hasKey("dapServer"):
      result.dapServer = j["dapServer"].getStr()
    if j.hasKey("dapConfig"):
      result.dapConfig = j["dapConfig"]
    else:
      result.dapConfig = newJObject()
    if j.hasKey("aiEnabled"):
      result.aiEnabled = j["aiEnabled"].getBool()
    if j.hasKey("aiAgent"):
      result.aiAgent = j["aiAgent"].getStr()
    if j.hasKey("aiApiKey"):
      result.aiApiKey = j["aiApiKey"].getStr()
    if j.hasKey("aiModel"):
      result.aiModel = j["aiModel"].getStr()
    if j.hasKey("aiBaseUrl"):
      result.aiBaseUrl = j["aiBaseUrl"].getStr()
    if j.hasKey("aiCommand"):
      result.aiCommand = j["aiCommand"].getStr()
    if j.hasKey("aiModelPreset"):
      result.aiModelPreset = j["aiModelPreset"].getStr()
    if j.hasKey("aiBuiltinModelProvider"):
      result.aiBuiltinModelProvider = j["aiBuiltinModelProvider"].getStr()
    if j.hasKey("aiBuiltinModel"):
      result.aiBuiltinModel = j["aiBuiltinModel"].getStr()
    if j.hasKey("aiLightweightModelProvider"):
      result.aiLightweightModelProvider = j["aiLightweightModelProvider"].getStr()
    if j.hasKey("aiLightweightModel"):
      result.aiLightweightModel = j["aiLightweightModel"].getStr()
    if j.hasKey("aiHeavyweightModelProvider"):
      result.aiHeavyweightModelProvider = j["aiHeavyweightModelProvider"].getStr()
    if j.hasKey("aiHeavyweightModel"):
      result.aiHeavyweightModel = j["aiHeavyweightModel"].getStr()
    if j.hasKey("aiEnabledModels") and j["aiEnabledModels"].kind == JArray:
      result.aiEnabledModels = @[]
      for item in j["aiEnabledModels"]:
        if item.kind == JString:
          result.aiEnabledModels.add(item.getStr())
    if j.hasKey("aiReasoningEffort"):
      let eff = j["aiReasoningEffort"].getStr().toLowerAscii()
      if eff == "high" or eff == "max":
        result.aiReasoningEffort = eff
    if j.hasKey("autoSave"):
      result.autoSave = j["autoSave"].getStr()
    if j.hasKey("autoSaveDelayMs"):
      result.autoSaveDelayMs = j["autoSaveDelayMs"].getInt()
    if j.hasKey("fileWatcherAutoReload"):
      result.fileWatcherAutoReload = j["fileWatcherAutoReload"].getBool()
    if j.hasKey("closedTabHistorySize"):
      result.closedTabHistorySize = j["closedTabHistorySize"].getInt()
    if j.hasKey("clipboardHistorySize"):
      result.clipboardHistorySize = j["clipboardHistorySize"].getInt()
    if j.hasKey("pinnedRecentFiles") and j["pinnedRecentFiles"].kind == JArray:
      result.pinnedRecentFiles = @[]
      for item in j["pinnedRecentFiles"]:
        if item.kind == JString:
          result.pinnedRecentFiles.add(item.getStr())
    if j.hasKey("searchCaseSensitive"):
      result.searchCaseSensitive = j["searchCaseSensitive"].getBool()
    if j.hasKey("searchUseRegex"):
      result.searchUseRegex = j["searchUseRegex"].getBool()
    if j.hasKey("searchWholeWord"):
      result.searchWholeWord = j["searchWholeWord"].getBool()
    if j.hasKey("searchRememberOptions"):
      result.searchRememberOptions = j["searchRememberOptions"].getBool()
    if j.hasKey("searchHistory") and j["searchHistory"].kind == JArray:
      result.searchHistory = @[]
      for item in j["searchHistory"]:
        if item.kind == JString:
          result.searchHistory.add(item.getStr())
  except CatchableError:
    discard

proc aiDisplayName*(config: AppConfig): string =
  ## Human-readable name for the active AI agent/model.
  let base = if config.aiAgent.len > 0: config.aiAgent.capitalizeAscii() else: "Kimi"
  if config.aiModel.len > 0:
    return base & " (" & config.aiModel & ")"
  return base

proc isBuiltinModelEnabled*(config: AppConfig; providerId, model: string): bool =
  ## Check whether a built-in model is enabled. An empty aiEnabledModels list
  ## means all models are enabled (backward compatible).
  if config.aiEnabledModels.len == 0:
    return true
  return (providerId & "/" & model) in config.aiEnabledModels

proc effectiveBuiltinModel*(config: AppConfig): tuple[provider, model: string] =
  ## Resolve lightweight/heavyweight/auto preset to a built-in model provider/model pair.
  let preset = config.aiModelPreset.toLowerAscii()
  if preset == "auto" and config.aiBuiltinModel.len > 0:
    return (config.aiBuiltinModelProvider, config.aiBuiltinModel)
  if preset == "lightweight" and config.aiLightweightModel.len > 0:
    return (config.aiLightweightModelProvider, config.aiLightweightModel)
  if preset == "heavyweight" and config.aiHeavyweightModel.len > 0:
    return (config.aiHeavyweightModelProvider, config.aiHeavyweightModel)
  return (config.aiBuiltinModelProvider, config.aiBuiltinModel)

proc saveConfig*(config: AppConfig) =
  createDir(configDir())
  var lspServersJ = newJObject()
  for key, val in config.lspServers:
    lspServersJ[key] = %val
  let j = %*{
    "windowWidth": config.windowWidth,
    "windowHeight": config.windowHeight,
    "windowTitle": config.windowTitle,
    "theme": config.themeName,
    "tabSize": config.tabSize,
    "autoIndent": config.autoIndent,
    "bracketHighlight": config.bracketHighlight,
    "autoCloseBrackets": config.autoCloseBrackets,
    "showLineNumbers": config.showLineNumbers,
    "lspServer": config.lspServer,
    "lspServers": lspServersJ,
    "lspConfig": config.lspConfig,
    "dapServer": config.dapServer,
    "dapConfig": config.dapConfig,
    "aiEnabled": config.aiEnabled,
    "aiAgent": config.aiAgent,
    "aiApiKey": config.aiApiKey,
    "aiModel": config.aiModel,
    "aiBaseUrl": config.aiBaseUrl,
    "aiCommand": config.aiCommand,
    "aiModelPreset": config.aiModelPreset,
    "aiBuiltinModelProvider": config.aiBuiltinModelProvider,
    "aiBuiltinModel": config.aiBuiltinModel,
    "aiLightweightModelProvider": config.aiLightweightModelProvider,
    "aiLightweightModel": config.aiLightweightModel,
    "aiHeavyweightModelProvider": config.aiHeavyweightModelProvider,
    "aiHeavyweightModel": config.aiHeavyweightModel,
    "aiEnabledModels": config.aiEnabledModels,
    "aiReasoningEffort": config.aiReasoningEffort,
    "autoSave": config.autoSave,
    "autoSaveDelayMs": config.autoSaveDelayMs,
    "fileWatcherAutoReload": config.fileWatcherAutoReload,
    "closedTabHistorySize": config.closedTabHistorySize,
    "clipboardHistorySize": config.clipboardHistorySize,
    "pinnedRecentFiles": config.pinnedRecentFiles,
    "searchCaseSensitive": config.searchCaseSensitive,
    "searchUseRegex": config.searchUseRegex,
    "searchWholeWord": config.searchWholeWord,
    "searchRememberOptions": config.searchRememberOptions,
    "searchHistory": config.searchHistory
  }
  writeFile(configPath(), $j & "\n")

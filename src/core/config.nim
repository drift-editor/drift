## Configuration loader
## Loads user settings from ~/.config/drift/config.json

import std/[os, json, strutils, tables]
import jsony

type
  AppConfig* = object
    windowWidth*: int
    windowHeight*: int
    windowTitle*: string
    theme*: string
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
    theme: "dark",
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
  let path = configPath()
  if not fileExists(path):
    return defaultConfig()
  try:
    result = readFile(path).fromJson(AppConfig)
    if result.tabSize < 1 or result.tabSize > 8:
      result.tabSize = 2
    let eff = result.aiReasoningEffort.toLowerAscii()
    if eff != "high" and eff != "max":
      result.aiReasoningEffort = "high"
  except:
    result = defaultConfig()

proc isModelEnabled*(config: AppConfig; providerId, model: string): bool =
  ## Check whether a model is enabled. An empty aiEnabledModels list
  ## means all models are enabled (backward compatible).
  if config.aiEnabledModels.len == 0:
    return true
  return (providerId & "/" & model) in config.aiEnabledModels

proc effectiveModel*(config: AppConfig): tuple[provider, model: string] =
  ## Resolve lightweight/heavyweight/auto preset to a provider/model pair.
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
  writeFile(configPath(), config.toJson() & "\n")

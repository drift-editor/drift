## Configuration loader
## Loads user settings from ~/.config/drift/config.json

import std/[os, json, strutils]

type
  AppConfig* = object
    windowWidth*: int
    windowHeight*: int
    windowTitle*: string
    themeName*: string
    lspServer*: string
    lspConfig*: JsonNode  # Server-specific LSP configuration
    dapServer*: string
    dapConfig*: JsonNode  # Server-specific DAP configuration
    aiEnabled*: bool
    aiProvider*: string
    aiApiKey*: string
    aiModel*: string
    aiBaseUrl*: string

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
    lspServer: "minlsp",
    lspConfig: newJObject(),
    dapServer: "nim_debug_adapter",
    dapConfig: newJObject(),
    aiEnabled: true
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
    if j.hasKey("lspServer"):
      result.lspServer = j["lspServer"].getStr()
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
    if j.hasKey("aiProvider"):
      result.aiProvider = j["aiProvider"].getStr()
    if j.hasKey("aiApiKey"):
      result.aiApiKey = j["aiApiKey"].getStr()
    if j.hasKey("aiModel"):
      result.aiModel = j["aiModel"].getStr()
    if j.hasKey("aiBaseUrl"):
      result.aiBaseUrl = j["aiBaseUrl"].getStr()
  except CatchableError:
    discard

proc aiDisplayName*(config: AppConfig): string =
  ## Human-readable name for the active AI provider.
  if config.aiProvider.len > 0:
    return config.aiProvider.capitalizeAscii()
  return "Kimi"

proc saveConfig*(config: AppConfig) =
  createDir(configDir())
  let j = %*{
    "windowWidth": config.windowWidth,
    "windowHeight": config.windowHeight,
    "windowTitle": config.windowTitle,
    "theme": config.themeName,
    "lspServer": config.lspServer,
    "lspConfig": config.lspConfig,
    "dapServer": config.dapServer,
    "dapConfig": config.dapConfig,
    "aiEnabled": config.aiEnabled,
    "aiProvider": config.aiProvider,
    "aiApiKey": config.aiApiKey,
    "aiModel": config.aiModel,
    "aiBaseUrl": config.aiBaseUrl
  }
  writeFile(configPath(), $j & "\n")

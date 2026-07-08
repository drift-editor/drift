## Search History Persistence
## Stores search queries separately from config.json so history can grow and be
## pruned independently.

import std/[os, json]

const MaxSearchHistory = 50

proc getSearchHistoryPath*(): string =
  ## Path to the search history JSON file.
  ## macOS: ~/Library/Application Support/Drift/search_history.json
  ## Others: ~/.config/drift/search_history.json
  when defined(macosx):
    let appSupportDir = getHomeDir() / "Library" / "Application Support" / "Drift"
    createDir(appSupportDir)
    appSupportDir / "search_history.json"
  else:
    let configDir = getConfigDir() / "drift"
    createDir(configDir)
    configDir / "search_history.json"

proc loadSearchHistory*(): seq[string] =
  ## Load persisted search history, ignoring malformed files.
  result = @[]
  let path = getSearchHistoryPath()
  if not fileExists(path):
    return
  try:
    let content = readFile(path)
    let jsonData = parseJson(content)
    if jsonData.kind != JArray:
      return
    for item in jsonData:
      if item.kind == JString:
        result.add(item.getStr())
      if result.len >= MaxSearchHistory:
        break
  except CatchableError:
    discard

proc saveSearchHistory*(history: seq[string]) =
  ## Save search history to disk, capped at MaxSearchHistory.
  try:
    createDir(getSearchHistoryPath().parentDir)
    var arr = newJArray()
    for i in countdown(history.high, max(0, history.len - MaxSearchHistory)):
      arr.add(%history[i])
    writeFile(getSearchHistoryPath(), $arr & "\n")
  except CatchableError:
    discard

proc mergeSearchHistory*(existing: seq[string]; incoming: seq[string]): seq[string] =
  ## Combine two histories, removing duplicates and keeping the most recent
  ## entries at the end. Result is capped at MaxSearchHistory.
  result = @[]
  for item in incoming:
    if item.len > 0 and item notin result:
      result.add(item)
  for item in existing:
    if item.len > 0 and item notin result:
      result.add(item)
  if result.len > MaxSearchHistory:
    result = result[^MaxSearchHistory .. ^1]

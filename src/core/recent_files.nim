## Recent Files Management
## Cross-platform recent files with macOS security-scoped bookmark support.
## Based on bale_sheet's recent_files.nim, adapted for drift.

import std/[os, json, options]
import ./security_scoped_bookmarks
export security_scoped_bookmarks.stopAccessingAllSecurityScopedResources

const MaxRecentFiles* = 10

type
  RecentFileEntry* = object
    path*: string
    bookmark*: string ## base64-encoded bookmark on macOS, empty elsewhere
    isFolder*: bool

proc getRecentFilesPath*(): string =
  ## Get the path to store recent files configuration.
  ## macOS: ~/Library/Application Support/Drift/recent_files.json
  ## Others: ~/.config/drift/recent_files.json
  when defined(macosx):
    let appSupportDir = getHomeDir() / "Library" / "Application Support" / "Drift"
    createDir(appSupportDir)
    appSupportDir / "recent_files.json"
  else:
    let configDir = getConfigDir() / "drift"
    createDir(configDir)
    configDir / "recent_files.json"

proc loadRecentFiles*(): seq[RecentFileEntry] =
  ## Load recent files from disk, validating bookmarks on macOS and
  ## checking file existence on all platforms.
  result = @[]
  let path = getRecentFilesPath()
  if not fileExists(path):
    return

  try:
    let content = readFile(path)
    let jsonData = parseJson(content)
    if jsonData.kind != JArray:
      return

    for item in jsonData:
      if item.kind != JObject:
        continue
      let filePath = item.getOrDefault("path").getStr("")
      let bookmark = item.getOrDefault("bookmark").getStr("")
      let isFolder = item.getOrDefault("isFolder").getBool(false)
      if filePath.len == 0:
        continue

      let pathValid = if isFolder: dirExists(filePath) else: fileExists(filePath)
      when defined(macosx):
        if bookmark.len > 0:
          let fb = FileBookmark(path: filePath, bookmarkData: bookmark)
          if validateBookmark(fb) and pathValid:
            result.add(RecentFileEntry(path: filePath, bookmark: bookmark, isFolder: isFolder))
        elif pathValid:
          result.add(RecentFileEntry(path: filePath, bookmark: "", isFolder: isFolder))
      else:
        if pathValid:
          result.add(RecentFileEntry(path: filePath, bookmark: "", isFolder: isFolder))
  except CatchableError:
    discard

proc saveRecentFiles*(files: seq[RecentFileEntry]) =
  ## Save recent files to disk.
  try:
    createDir(getRecentFilesPath().parentDir)
    var jsonArray = newJArray()
    for f in files:
      var obj = newJObject()
      obj["path"] = %f.path
      obj["bookmark"] = %f.bookmark
      obj["isFolder"] = %f.isFolder
      jsonArray.add(obj)
    writeFile(getRecentFilesPath(), $jsonArray & "\n")
  except CatchableError:
    discard

proc addToRecentFiles*(files: seq[RecentFileEntry], filePath: string; isFolder: bool = false): seq[RecentFileEntry] =
  ## Add a file or folder to the recent files list.
  ## - Removes duplicates
  ## - Moves to front
  ## - Caps at MaxRecentFiles
  ## - On macOS, creates a security-scoped bookmark
  if filePath.len == 0:
    return files
  if isFolder:
    if not dirExists(filePath):
      return files
  else:
    if not fileExists(filePath):
      return files

  when defined(macosx):
    let bookmarkOpt = createBookmarkForFile(filePath)
    let bookmark = if bookmarkOpt.isSome: bookmarkOpt.get().bookmarkData else: ""
  else:
    let bookmark = ""

  result = @[RecentFileEntry(path: filePath, bookmark: bookmark, isFolder: isFolder)]
  for existing in files:
    if existing.path != filePath and result.len < MaxRecentFiles:
      result.add(existing)

proc recentPaths*(files: seq[RecentFileEntry]): seq[string] =
  ## Extract just the file paths for UI display.
  result = newSeq[string](files.len)
  for i, f in files:
    result[i] = f.path

proc recentItems*(files: seq[RecentFileEntry]): seq[tuple[path: string, isFolder: bool]] =
  ## Extract paths with folder flag for welcome screen display.
  result = newSeq[tuple[path: string, isFolder: bool]](files.len)
  for i, f in files:
    result[i] = (path: f.path, isFolder: f.isFolder)

proc startAccessingRecentFile*(files: seq[RecentFileEntry], filePath: string): bool =
  ## Prepare to open a recent file. On macOS this resolves the security-scoped
  ## bookmark and starts accessing the resource. Returns true if the file is
  ## accessible. If the bookmark is stale on macOS, returns false (caller should
  ## reload the recent files list to prune dead entries).
  for f in files:
    if f.path == filePath:
      when defined(macosx):
        if f.bookmark.len > 0:
          let fb = FileBookmark(path: f.path, bookmarkData: f.bookmark)
          return startAccessingBookmark(fb)
      return fileExists(filePath)
  return false

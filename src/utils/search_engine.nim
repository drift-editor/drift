## Platform-aware search engine helpers
## Chooses ripgrep (rg) when available, falls back to grep on Unix or
## findstr on Windows, and finally to a pure-Nim recursive fallback when no
## external tool is present.

import std/[os, strutils, osproc, re]

type
  SearchTool* = enum
    stRipgrep
    stGrep
    stFindstr
    stFallback

const
  DefaultExcludedDirs* = [".git", "node_modules", ".nimble", "dist", "build", ".cache"]
  DefaultExcludedExts* = [".exe", ".dll", ".so", ".dylib", ".png", ".jpg", ".jpeg",
                          ".gif", ".ico", ".woff", ".woff2", ".ttf", ".eot", ".mp3",
                          ".mp4", ".avi", ".mov", ".zip", ".tar", ".gz", ".rar",
                          ".7z", ".pdf", ".doc", ".docx", ".xls", ".xlsx"]

proc detectSearchTool*(): SearchTool =
  ## Pick the best available search tool for the current platform.
  if findExe("rg").len > 0:
    return stRipgrep
  when defined(windows):
    if findExe("findstr").len > 0:
      return stFindstr
  else:
    if findExe("grep").len > 0:
      return stGrep
  return stFallback

proc isExcludedDir(name: string; excludedDirs: openArray[string]): bool =
  for d in excludedDirs:
    if name == d:
      return true
  return false

proc isExcludedExt(path: string; excludedExts: openArray[string]): bool =
  let ext = path.splitFile.ext.toLowerAscii()
  for e in excludedExts:
    if ext == e:
      return true
  return false

proc shouldSkipPath(path: string; excludedDirs, excludedExts: openArray[string]): bool =
  if path.len == 0: return false
  let name = extractFilename(path)
  if isExcludedDir(name, excludedDirs):
    return true
  if fileExists(path) and isExcludedExt(path, excludedExts):
    return true
  return false

proc buildSearchTextCmd*(pattern: string; workspaceRoot: string;
                         caseSensitive, useRegex: bool;
                         excludedDirs: openArray[string] = DefaultExcludedDirs;
                         excludedExts: openArray[string] = DefaultExcludedExts): string =
  ## Build a command that searches file contents and prints matches in the
  ## ``path:line:preview`` format. Returns "" if no external tool is available
  ## (caller should use the fallback).
  let tool = detectSearchTool()
  let quotedPattern = quoteShell(pattern)
  case tool
  of stRipgrep:
    var cmd = "rg -n --no-heading --color never"
    if not caseSensitive: cmd &= " -i"
    if not useRegex: cmd &= " -F"
    var excludeArg = ""
    for dir in excludedDirs:
      if excludeArg.len > 0: excludeArg.add(" ")
      excludeArg.add("--glob !*/" & dir & "/*")
    for ext in excludedExts:
      if excludeArg.len > 0: excludeArg.add(" ")
      excludeArg.add("--glob !*" & ext)
    cmd &= " " & excludeArg & " -- " & quotedPattern & " ."
    return cmd
  of stGrep:
    var cmd = "grep -rn"
    if not caseSensitive: cmd &= " -i"
    if not useRegex: cmd &= " -F"
    var excludeArg = ""
    for dir in excludedDirs:
      if excludeArg.len > 0: excludeArg.add(" ")
      excludeArg.add("--exclude-dir=" & quoteShell(dir))
    for ext in excludedExts:
      if excludeArg.len > 0: excludeArg.add(" ")
      excludeArg.add("--exclude=*" & ext)
    cmd &= " " & excludeArg & " -- " & quotedPattern & " ."
    return cmd
  of stFindstr:
    var cmd = "findstr /n /s"
    if not caseSensitive: cmd &= " /i"
    if useRegex: cmd &= " /r"
    else: cmd &= " /l"
    # findstr has limited exclusion support; skip extensions only via /c:path exclusions
    for ext in excludedExts:
      cmd &= " /c:" & quoteShell("*" & ext)
    cmd &= " " & quotedPattern & " *"
    return cmd
  of stFallback:
    return ""

proc buildFindFilesCmd*(pattern: string; workspaceRoot: string;
                        excludedDirs: openArray[string] = DefaultExcludedDirs;
                        excludedExts: openArray[string] = DefaultExcludedExts): string =
  ## Build a command that lists files matching a glob. Returns "" if no
  ## external tool is available.
  let tool = detectSearchTool()
  case tool
  of stRipgrep:
    return "rg --files -g " & quoteShell(pattern) & " ."
  of stGrep:
    # No native glob support; use shell find + grep as a reasonable fallback.
    return "find . -type f -print"
  of stFindstr:
    return "dir /s /b *"
  of stFallback:
    return ""

proc fallbackSearchText*(pattern, workspaceRoot: string;
                         caseSensitive, useRegex: bool;
                         excludedDirs: openArray[string] = DefaultExcludedDirs;
                         excludedExts: openArray[string] = DefaultExcludedExts): string =
  ## Pure-Nim recursive text search fallback. Returns output in
  ## ``path:line:preview`` format.
  result = ""
  if pattern.len == 0: return
  let pat = if caseSensitive: pattern else: pattern.toLowerAscii()
  var matches = 0
  const MaxMatches = 500
  for path in walkDirRec(workspaceRoot):
    if shouldSkipPath(path, excludedDirs, excludedExts):
      continue
    if not fileExists(path):
      continue
    var content = ""
    try:
      content = readFile(path)
    except CatchableError:
      continue
    let target = if caseSensitive: content else: content.toLowerAscii()
    let relPath = relativePath(path, workspaceRoot)
    var lineStart = 0
    var lineNum = 1
    var i = 0
    while i <= target.len - pat.len:
      var found = false
      if useRegex:
        # Regex fallback is expensive; only support it when we have no choice.
        try:
          let rePat = re(pat)
          let bounds = target.findBounds(rePat, i)
          if bounds.first >= 0:
            i = bounds.first
            found = true
        except RegexError:
          return "Error: invalid regex"
      else:
        if target[i ..< i + pat.len] == pat:
          found = true
      if found:
        # Find line boundaries around the match.
        var start = i
        while start > lineStart and target[start - 1] notin {'\L', '\r'}:
          dec start
        var lineEnd = i + pat.len
        while lineEnd < target.len and target[lineEnd] notin {'\L', '\r'}:
          inc lineEnd
        let preview = content[start ..< min(lineEnd, content.len)]
        if result.len > 0: result.add("\n")
        result.add(relPath & ":" & $lineNum & ":" & preview)
        inc matches
        if matches >= MaxMatches:
          return
        i = lineEnd
        lineStart = lineEnd
        while i < target.len and target[i] in {'\L', '\r'}:
          if i + 1 < target.len and target[i] == '\r' and target[i + 1] == '\l':
            inc i
          inc i
          inc lineNum
          lineStart = i
      else:
        if i < target.len and target[i] == '\L':
          lineStart = i + 1
          inc lineNum
        inc i

proc matchGlobPattern*(path, pattern: string): bool =
  ## Simple glob matcher supporting '*' and '?'.
  var i = 0
  var j = 0
  result = true
  while i < pattern.len and j < path.len:
    if pattern[i] == '*':
      inc i
      if i >= pattern.len:
        j = path.len
        break
      let next = pattern[i]
      while j < path.len and path[j] != next:
        inc j
      if j >= path.len:
        return false
    elif pattern[i] == '?':
      inc i
      inc j
    else:
      if pattern[i] != path[j]:
        return false
      inc i
      inc j
  if i < pattern.len and pattern[i] == '*':
    inc i
  return i == pattern.len and j == path.len

proc fallbackFindFiles*(pattern, workspaceRoot: string;
                        excludedDirs: openArray[string] = DefaultExcludedDirs;
                        excludedExts: openArray[string] = DefaultExcludedExts): string =
  ## Pure-Nim recursive file listing fallback using glob matching.
  result = ""
  if pattern.len == 0: return
  for path in walkDirRec(workspaceRoot):
    if shouldSkipPath(path, excludedDirs, excludedExts):
      continue
    if not fileExists(path):
      continue
    let relPath = relativePath(path, workspaceRoot)
    if relPath.matchGlobPattern(pattern):
      if result.len > 0: result.add("\n")
      result.add(relPath)

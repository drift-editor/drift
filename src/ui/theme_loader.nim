## Theme loader from YAML files

import std/[os, tables, strutils, json, algorithm]
import yaml/tojson
import uirelays/screen
import theme

proc parseColorHex(hex: string): Color =
  var h = hex.strip()
  if h.startsWith("#"): h = h[1..^1]
  h = h.toLowerAscii()

  if h.len == 3:
    let r = parseHexInt($h[0] & $h[0]).uint8
    let g = parseHexInt($h[1] & $h[1]).uint8
    let b = parseHexInt($h[2] & $h[2]).uint8
    result = color(r, g, b, 255)
  elif h.len == 6:
    let r = parseHexInt(h[0..1]).uint8
    let g = parseHexInt(h[2..3]).uint8
    let b = parseHexInt(h[4..5]).uint8
    result = color(r, g, b, 255)
  elif h.len == 8:
    let r = parseHexInt(h[0..1]).uint8
    let g = parseHexInt(h[2..3]).uint8
    let b = parseHexInt(h[4..5]).uint8
    let a = parseHexInt(h[6..7]).uint8
    result = color(r, g, b, a)
  else:
    result = color(255, 255, 255, 255)

proc loadThemeFromYaml*(path: string): Theme =
  result = darkTheme()
  if not fileExists(path):
    return result
  try:
    let yamlData = readFile(path)
    let docs = loadToJson(yamlData)
    if docs.len == 0:
      return result
    let j = docs[0]

    var colorMap = initTable[string, ThemeColor]()
    colorMap["background"]       = tcBackground
    colorMap["surface"]          = tcSurface
    colorMap["surfaceHover"]     = tcSurfaceHover
    colorMap["border"]           = tcBorder
    colorMap["text"]             = tcText
    colorMap["textSecondary"]    = tcTextSecondary
    colorMap["textDisabled"]     = tcTextDisabled
    colorMap["accent"]           = tcAccent
    colorMap["accentHover"]      = tcAccentHover
    colorMap["cursor"]           = tcCursor
    colorMap["selection"]        = tcSelection
    colorMap["lineNumber"]       = tcLineNumber
    colorMap["lineNumberActive"] = tcLineNumberActive
    colorMap["gutter"]           = tcGutter
    colorMap["success"]          = tcSuccess
    colorMap["warning"]          = tcWarning
    colorMap["error"]            = tcError
    colorMap["info"]             = tcInfo

    var syntaxMap = initTable[string, SyntaxColor]()
    syntaxMap["default"]     = synDefault
    syntaxMap["keyword"]     = synKeyword
    syntaxMap["controlFlow"] = synControlFlow
    syntaxMap["string"]      = synString
    syntaxMap["comment"]     = synComment
    syntaxMap["number"]      = synNumber
    syntaxMap["function"]    = synFunction
    syntaxMap["type"]        = synType
    syntaxMap["builtin"]     = synBuiltin
    syntaxMap["variable"]    = synVariable
    syntaxMap["operator"]    = synOperator
    syntaxMap["punctuation"] = synPunctuation
    syntaxMap["procName"]    = synProcName
    syntaxMap["exportMark"]  = synExportMark
    syntaxMap["markdownFence"]    = synMarkdownFence
    syntaxMap["markdownLanguage"] = synMarkdownLanguage

    if j.hasKey("colors"):
      let colors = j["colors"]
      for key, tc in colorMap:
        if colors.hasKey(key):
          result.colors[tc] = parseColorHex(colors[key].getStr())

    if j.hasKey("syntax"):
      let syntax = j["syntax"]
      for key, sc in syntaxMap:
        if syntax.hasKey(key):
          result.syntax[sc] = parseColorHex(syntax[key].getStr())

  except CatchableError as e:
    echo "[theme] failed to load ", path, ": ", e.msg
    result = darkTheme()

proc loadThemeByName*(name: string): Theme =
  let baseDir = currentSourcePath().parentDir / ".." / ".." / "resources" / "themes"
  let path = baseDir / (name & ".yml")
  result = loadThemeFromYaml(path)

proc listAvailableThemes*(): seq[string] =
  result = @[]
  let baseDir = currentSourcePath().parentDir / ".." / ".." / "resources" / "themes"
  if dirExists(baseDir):
    for file in walkDir(baseDir):
      if file.kind == pcFile and file.path.endsWith(".yml"):
        let name = extractFilename(file.path)
        result.add(name[0..^5])  # Strip .yml
    result.sort(proc(a, b: string): int = cmp(a, b))

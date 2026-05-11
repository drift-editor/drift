## Sticky scroll computation and rendering for Nim-like indentation-based languages

import std/strutils
import uirelays
import widgets/theme as synTheme
import nim_highlighter

type
  StickyLine* = object
    line*: int
    text*: string

proc leadingSpaces(line: string): int =
  for c in line:
    if c == ' ': inc result
    elif c == '\t': inc result, 2
    else: break

proc isScopeHeader(line: string): bool =
  let s = line.strip(leading = true, trailing = false)
  if s.len == 0: return false
  if s.startsWith("#"): return false
  const keywords = ["proc ", "func ", "macro ", "template ", "iterator ",
                    "method ", "converter ", "type ", "var ", "let ",
                    "const ", "when ", "if ", "elif ", "else", "case ",
                    "of ", "while ", "for ", "block",
                    "try", "except",
                    "finally", "enum ", "object ", "concept ",
                    "mixin ", "bind "]
  for k in keywords:
    if s.startsWith(k):
      # Guard against identifier prefixes (e.g. "elsewhere" matching "else")
      if s.len == k.len or s[k.len] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        return true
  if s.endsWith("=") or s.endsWith("=>"): return true
  false

proc computeStickyLines*(lines: seq[string], firstLine: int, maxLines: int = 5): seq[StickyLine] =
  if lines.len == 0 or firstLine >= lines.len or firstLine < 0:
    return
  var targetIndent = leadingSpaces(lines[firstLine])
  var tmp: seq[StickyLine] = @[]
  for i in countdown(firstLine - 1, 0):
    let indent = leadingSpaces(lines[i])
    if indent < targetIndent:
      if isScopeHeader(lines[i]):
        tmp.add(StickyLine(line: i, text: lines[i].strip(trailing = true)))
        targetIndent = indent
        if tmp.len >= maxLines: break
  for i in countdown(tmp.high, 0):
    result.add(tmp[i])

proc drawHighlightedLine*(font: Font; x, y: int; text: string; theme: synTheme.Theme; defaultColor: Color) =
  ## Draw a line with Nim syntax highlighting
  ## Delegates to the shared nim_highlighter module
  drawHighlightedNimLine(font, x, y, text, color(0, 0, 0, 0))

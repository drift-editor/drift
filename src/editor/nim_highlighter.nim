## Lightweight Nim syntax highlighter for single-line snippets
## Shared by sticky_scroll.nim and hover_tooltip.nim

import uirelays
import ../ui/theme

const
  NimKeywords* = ["addr", "and", "as", "asm", "atomic", "bind", "block",
    "break", "case", "cast", "concept", "const", "continue", "converter",
    "defer", "discard", "distinct", "div", "do", "elif", "else", "end",
    "enum", "except", "export", "finally", "for", "from", "func",
    "if", "import", "in", "include", "interface", "is", "isnot",
    "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
    "notin", "object", "of", "or", "out", "proc", "ptr", "raise",
    "ref", "return", "shl", "shr", "static", "template", "try",
    "tuple", "type", "using", "var", "when", "while", "xor", "yield"]

  NimTypes* = ["int", "int8", "int16", "int32", "int64", "uint", "uint8",
    "uint16", "uint32", "uint64", "float", "float32", "float64",
    "char", "string", "bool", "byte", "seq", "array", "set", "range",
    "openArray", "varargs", "cstring", "pointer", "void", "auto",
    "untyped", "typed", "clong", "culong", "cchar", "cschar", "cshort",
    "cint", "csize_t", "cstringArray"]

proc isIdentStart*(c: char): bool {.inline.} = 
  c in {'a'..'z', 'A'..'Z', '_'}

proc isIdentChar*(c: char): bool {.inline.} = 
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc tokenColor*(word: string): Color =
  ## Determine the color for an identifier/keyword
  if word in NimKeywords: return currentTheme.getSyntaxColor(synKeyword)
  if word in NimTypes: return currentTheme.getSyntaxColor(synType)
  if word.len > 0 and word[0] in {'A'..'Z'}: return currentTheme.getSyntaxColor(synType)
  if word == "result": return currentTheme.getSyntaxColor(synKeyword)
  return currentTheme.getColor(tcText)

proc drawHighlightedNimLine*(font: Font; x, y: int; text: string; bg: Color) =
  ## Draw a single line of Nim code with syntax highlighting
  ## Uses character-by-character rendering for accurate positioning
  var i = 0
  var cx = x
  
  while i < text.len:
    let c = text[i]
    
    # Comment to end of line
    if c == '#':
      discard drawText(font, cx, y, text[i..^1], currentTheme.getSyntaxColor(synComment), bg)
      break
    
    # String literals (double or single quotes)
    elif c == '"' or c == '\'':
      var j = i + 1
      let delim = c
      while j < text.len and text[j] != delim:
        if text[j] == '\\' and j + 1 < text.len: inc j, 2
        else: inc j
      if j < text.len: inc j
      let lit = text[i..<j]
      discard drawText(font, cx, y, lit, currentTheme.getSyntaxColor(synString), bg)
      cx += measureText(font, lit).w
      i = j
    
    # Backtick strings
    elif c == '`':
      var j = i + 1
      while j < text.len and text[j] != '`': inc j
      if j < text.len: inc j
      let lit = text[i..<j]
      discard drawText(font, cx, y, lit, currentTheme.getSyntaxColor(synString), bg)
      cx += measureText(font, lit).w
      i = j
    
    # Numbers
    elif c in {'0'..'9'}:
      var j = i
      while j < text.len and text[j] in {'0'..'9', '.', '_', 'x', 'X', 'b', 'B', 'o', 'O', 'a'..'f', 'A'..'F'}: inc j
      let num = text[i..<j]
      discard drawText(font, cx, y, num, currentTheme.getSyntaxColor(synNumber), bg)
      cx += measureText(font, num).w
      i = j
    
    # Identifiers and keywords
    elif isIdentStart(c):
      var j = i
      while j < text.len and isIdentChar(text[j]): inc j
      let word = text[i..<j]
      var col = tokenColor(word)
      # Heuristic: word followed by '(' is likely a proc call
      if j < text.len and text[j] == '(' and word notin NimKeywords and word notin NimTypes and word[0] in {'a'..'z', '_'}:
        col = currentTheme.getSyntaxColor(synProcName)
      discard drawText(font, cx, y, word, col, bg)
      cx += measureText(font, word).w
      i = j
    
    # Punctuation
    elif c in {'(', ')', '[', ']', '{', '}', ',', ';', ':', '.'}:
      discard drawText(font, cx, y, $c, currentTheme.getSyntaxColor(synPunctuation), bg)
      cx += measureText(font, $c).w
      inc i
    
    # Operators
    elif c in {'+', '-', '*', '/', '=', '<', '>', '@', '$', '~', '&', '%', '|', '^'}:
      discard drawText(font, cx, y, $c, currentTheme.getSyntaxColor(synOperator), bg)
      cx += measureText(font, $c).w
      inc i
    
    # Everything else (including whitespace)
    else:
      discard drawText(font, cx, y, $c, currentTheme.getColor(tcText), bg)
      cx += measureText(font, $c).w
      inc i

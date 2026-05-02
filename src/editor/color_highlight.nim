import std/strutils
import uirelays
import color_parser

const
  MaxScanSize = 500_000
  MaxFuncLength = 60

proc scanColorHighlights*(text: string): seq[tuple[a, b: int, color: Color]] =
  result = @[]
  if text.len > MaxScanSize:
    return

  var found: seq[tuple[a, b: int, c: Color]] = @[]

  const funcPrefixes = ["rgba(", "rgb(", "hsla(", "hsl("]

  var i = 0
  while i < text.len:
    # Hex colors
    if text[i] == '#':
      var j = i + 1
      while j < text.len and text[j] in HexDigits:
        inc j
      let hexLen = j - (i + 1)
      if hexLen in [3, 4, 6, 8]:
        let s = text[i ..< j]
        try:
          let c = parseColor(s)
          found.add((i, j - 1, c))
        except CatchableError:
          discard
      i = j
      continue

    # rgb/rgba/hsl/hsla functions
    var matchedFunc = false
    if text[i] in {'r', 'R', 'h', 'H'}:
      for p in funcPrefixes:
        if i + p.len <= text.len and text[i ..< i + p.len] == p:
          let close = text.find(')', i + p.len)
          if close >= 0 and (close - i) <= MaxFuncLength:
            let s = text[i .. close]
            try:
              let c = parseColor(s)
              found.add((i, close, c))
            except CatchableError:
              discard
            i = close + 1
            matchedFunc = true
            break
      if matchedFunc:
        continue

    # Named colors
    if text[i] in {'a'..'z', 'A'..'Z'}:
      var j = i
      while j < text.len and text[j] in {'a'..'z', 'A'..'Z'}:
        inc j
      let word = text[i ..< j]
      try:
        let c = parseColor(word)
        found.add((i, j - 1, c))
      except CatchableError:
        discard
      i = j
    else:
      inc i

  for f in found:
    result.add((f.a, f.b, f.c))

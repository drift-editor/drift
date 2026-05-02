import std/strutils

proc splitLinesKeep*(s: string): seq[string] =
  ## Like splitLines but preserves the trailing empty line when the string ends with a newline.
  ## Handles \\r\\n, \\r, and \\n.
  if s.len == 0:
    return @[""]
  result = @[]
  var i = 0
  var start = 0
  while i < s.len:
    if s[i] == '\r':
      if i + 1 < s.len and s[i + 1] == '\n':
        result.add(s[start ..< i])
        i += 2
        start = i
      else:
        result.add(s[start ..< i])
        i += 1
        start = i
    elif s[i] == '\n':
      result.add(s[start ..< i])
      i += 1
      start = i
    else:
      i += 1
  result.add(s[start .. ^1])

proc lineCount*(s: string): int =
  ## Number of lines in a string (equivalent to splitLinesKeep.len).
  s.count('\n') + 1

proc lastLineLen*(s: string): int =
  ## Length of the last line (characters after the final newline).
  let idx = s.rfind('\n')
  if idx < 0: s.len else: s.len - idx - 1

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
  ## Handles both \n and \r line endings.
  var count = 0
  for c in s:
    if c == '\n' or c == '\r':
      count += 1
  count + 1

proc lastLineLen*(s: string): int =
  ## Length of the last line (characters after the final newline).
  ## Handles both \n and \r line endings.
  var idx = -1
  for i, c in s:
    if c == '\n' or c == '\r':
      idx = i
  if idx < 0: s.len else: s.len - idx - 1

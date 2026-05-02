import std/[osproc, strutils, os]

type
  DiffLine* = tuple[line: int, kind: char]

proc parseHunkHeader(header: string): tuple[oldStart, oldCount, newStart, newCount: int] =
  let atIdx = header.find("@@")
  if atIdx < 0: return
  let secondAt = header.find("@@", atIdx + 2)
  if secondAt < 0: return
  let inner = header[atIdx + 2 ..< secondAt].strip()
  let parts = inner.splitWhitespace()
  if parts.len < 2: return

  template parsePart(s: string, outStart, outCount: int) =
    let withoutSign = s[1..^1]
    let commaIdx = withoutSign.find(',')
    if commaIdx >= 0:
      outStart = parseInt(withoutSign[0..<commaIdx])
      outCount = parseInt(withoutSign[commaIdx + 1..^1])
    else:
      outStart = parseInt(withoutSign)
      outCount = 1

  if parts[0].startsWith("-"):
    parsePart(parts[0], result.oldStart, result.oldCount)
  if parts[1].startsWith("+"):
    parsePart(parts[1], result.newStart, result.newCount)

proc getDiffLines*(path: string): seq[DiffLine] =
  result = @[]
  if path.len == 0 or not fileExists(path):
    return

  let dir = path.parentDir()
  let cmd = "git diff -U0 --no-color -- " & path.extractFilename().quoteShell()
  let (output, exitCode) = execCmdEx(cmd, workingDir = dir)
  if exitCode != 0 or output.len == 0:
    return

  var inHunk = false
  var oldLineNum = 0
  var newLineNum = 0
  var pendingDeletions: seq[int] = @[]

  for line in splitLines(output):
    if line.startsWith("@@"):
      for d in pendingDeletions:
        result.add((d, 'D'))
      pendingDeletions.setLen(0)
      let (os, _, ns, _) = parseHunkHeader(line)
      oldLineNum = os
      newLineNum = ns
      inHunk = true
      continue

    if not inHunk:
      continue

    if line.len == 0:
      continue

    case line[0]
    of ' ':
      oldLineNum += 1
      newLineNum += 1
    of '+':
      if pendingDeletions.len > 0:
        result.add((newLineNum - 1, 'M'))
        pendingDeletions.delete(pendingDeletions.high)
      else:
        result.add((newLineNum - 1, 'A'))
      newLineNum += 1
    of '-':
      pendingDeletions.add(oldLineNum)
      oldLineNum += 1
    else:
      discard

  for d in pendingDeletions:
    result.add((d - 1, 'D'))
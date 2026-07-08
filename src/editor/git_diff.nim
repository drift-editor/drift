import std/[osproc, strutils, os]
import ../services/git as gitcmd

type
  DiffLine* = tuple[line: int, kind: char]

  DiffHunk* = object
    oldStart*: int
    oldCount*: int
    newStart*: int
    newCount*: int
    lines*: seq[string]

proc parseHunkHeader(header: string): tuple[oldStart, oldCount, newStart, newCount: int] =
  let atIdx = header.find("@@")
  if atIdx < 0: return
  let secondAt = header.find("@@", atIdx + 2)
  if secondAt < 0: return
  let inner = header[atIdx + 2 ..< secondAt].strip()
  let parts = inner.splitWhitespace()
  if parts.len < 2: return

  proc parsePart(s: string, outStart, outCount: var int): bool =
    let withoutSign = s[1..^1]
    let commaIdx = withoutSign.find(',')
    try:
      if commaIdx >= 0:
        outStart = parseInt(withoutSign[0..<commaIdx])
        outCount = parseInt(withoutSign[commaIdx + 1..^1])
      else:
        outStart = parseInt(withoutSign)
        outCount = 1
      return true
    except ValueError:
      return false

  if parts[0].startsWith("-"):
    if not parsePart(parts[0], result.oldStart, result.oldCount): return
  if parts[1].startsWith("+"):
    if not parsePart(parts[1], result.newStart, result.newCount): return

proc getDiffLines*(path: string): seq[DiffLine] =
  result = @[]
  if path.len == 0 or not fileExists(path):
    return

  let repoRoot = gitcmd.getRepoRoot(path)
  if repoRoot.len == 0:
    return
  let absPath = expandFilename(path)
  let absRepo = expandFilename(repoRoot)
  let relPath = relativePath(absPath, absRepo)
  let cmd = "git diff -U0 --no-color -- " & relPath.quoteShell()
  let (output, exitCode) = execCmdEx(cmd, workingDir = absRepo)
  if exitCode != 0 or output.len == 0:
    return

  var inHunk = false
  var oldLineNum = 0
  var newLineNum = 0
  var pendingDeletions: seq[int] = @[]

  for line in splitLines(output):
    if line.startsWith("@@"):
      for d in pendingDeletions:
        result.add((d - 1, 'D'))
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

proc parseDiffHunks*(path: string; staged: bool = false): seq[DiffHunk] =
  ## Parse `git diff` output for `path` into a list of unified hunks.
  if path.len == 0 or not fileExists(path):
    return

  let repoRoot = gitcmd.getRepoRoot(path)
  if repoRoot.len == 0:
    return
  let absPath = expandFilename(path)
  let absRepo = expandFilename(repoRoot)
  let relPath = relativePath(absPath, absRepo)

  var args = @["diff", "-U1", "--no-color"]
  if staged:
    args.add("--cached")
  args.add("--")
  args.add(relPath)

  let (output, exitCode) = gitcmd.execGitCommand(args, absRepo)
  if exitCode != 0 or output.len == 0:
    return

  var inHunk = false
  for line in splitLines(output):
    if line.startsWith("@@"):
      let (os, oc, ns, nc) = parseHunkHeader(line)
      if ns == 0 and nc == 0 and os == 0 and oc == 0:
        inHunk = false
        continue
      result.add(DiffHunk(
        oldStart: os, oldCount: oc, newStart: ns, newCount: nc, lines: @[]))
      inHunk = true
      continue

    if not inHunk:
      continue

    if line.len == 0:
      continue

    case line[0]
    of ' ', '-', '+':
      result[^1].lines.add(line)
    of '\\':
      discard  # "\ No newline at end of file" marker
    else:
      inHunk = false

proc findHunkAtLine*(hunks: seq[DiffHunk]; line: int): int =
  ## Return the index of the hunk covering the given 0-based new-file line,
  ## or -1 if none.  Only hunks with a non-empty new-file range are considered.
  let oneBased = line + 1
  for i, h in hunks:
    if h.newCount <= 0:
      continue
    if oneBased >= h.newStart and oneBased < h.newStart + h.newCount:
      return i
  return -1

proc hunkOldText*(h: DiffHunk; eol: string = "\n"): string =
  ## Reconstruct the old-file side of a hunk (context + deleted lines).
  var parts: seq[string]
  for line in h.lines:
    if line.len > 0 and (line[0] == ' ' or line[0] == '-'):
      parts.add(line[1..^1])
  parts.join(eol)

proc hunkNewText*(h: DiffHunk; eol: string = "\n"): string =
  ## Reconstruct the new-file side of a hunk (context + added lines).
  var parts: seq[string]
  for line in h.lines:
    if line.len > 0 and (line[0] == ' ' or line[0] == '+'):
      parts.add(line[1..^1])
  parts.join(eol)

proc revertHunk*(path: string; h: DiffHunk): bool =
  ## Revert a single diff hunk in `path` by applying it in reverse with `git apply`.
  ## Returns `true` if git reports success.
  if path.len == 0 or not fileExists(path):
    return false
  let repoRoot = gitcmd.getRepoRoot(path)
  if repoRoot.len == 0:
    return false
  let absPath = expandFilename(path)
  let absRepo = expandFilename(repoRoot)
  let relPath = relativePath(absPath, absRepo)

  var patch = "diff --git a/" & relPath & " b/" & relPath & "\n"
  patch.add("--- a/" & relPath & "\n")
  patch.add("+++ b/" & relPath & "\n")
  if h.oldCount <= 0 and h.newCount <= 0:
    return false
  let oldRange = $h.oldStart & "," & $h.oldCount
  let newRange = $h.newStart & "," & $h.newCount
  patch.add("@@ -" & oldRange & " +" & newRange & " @@\n")
  for line in h.lines:
    patch.add(line & "\n")

  let tmpPatch = getTempDir() / "drift_revert_hunk.patch"
  try:
    writeFile(tmpPatch, patch)
  except CatchableError:
    return false

  let args = @["apply", "--reverse", tmpPatch]
  let (_, exitCode) = gitcmd.execGitCommand(args, absRepo)
  try:
    removeFile(tmpPatch)
  except CatchableError:
    discard
  result = exitCode == 0


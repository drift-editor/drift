## Git command interface — pure git operations, no UI state.

import std/[os, osproc, streams, strutils, tables]

type
  GitFileStatus* = enum
    gfsUnmodified, gfsModified, gfsAdded, gfsDeleted,
    gfsRenamed, gfsConflict, gfsUntracked

  GitFileChange* = object
    path*: string
    stagedStatus*: GitFileStatus
    workingStatus*: GitFileStatus
    stagedAdded*: int
    stagedRemoved*: int
    unstagedAdded*: int
    unstagedRemoved*: int

proc execGitCommand*(args: openArray[string], workingDir: string = ""): tuple[output: string, exitCode: int] =
  try:
    let process = startProcess(
      "git",
      args = @args,
      workingDir = if workingDir.len > 0: workingDir else: "",
      options = {poUsePath, poStdErrToStdOut}
    )
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    (output, exitCode)
  except:
    ("", -1)

proc isGitRepository*(path: string): bool =
  let (_, exitCode) = execGitCommand(["rev-parse", "--git-dir"], path)
  exitCode == 0

proc getRepoRoot*(path: string): string =
  ## Find the git repository root for a given path (file or directory).
  let dir = if dirExists(path): path else: parentDir(path)
  let (output, exitCode) = execGitCommand(["rev-parse", "--show-toplevel"], dir)
  if exitCode == 0: output.strip() else: ""

proc getCurrentBranch*(path: string): string =
  let (output, exitCode) = execGitCommand(["branch", "--show-current"], path)
  if exitCode == 0: output.strip() else: "unknown"

proc getRepoStatus*(path: string): tuple[ahead, behind: int] =
  let (output, exitCode) = execGitCommand(
    ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], path)
  if exitCode == 0:
    let parts = output.strip().splitWhitespace()
    if parts.len >= 2:
      try:
        result.ahead = parseInt(parts[0])
        result.behind = parseInt(parts[1])
      except: discard

proc charToStatus*(c: char): GitFileStatus =
  case c
  of 'M': gfsModified
  of 'A': gfsAdded
  of 'D': gfsDeleted
  of 'R': gfsRenamed
  of 'U': gfsConflict
  of '?': gfsUntracked
  else: gfsUnmodified

proc parseGitStatus*(path: string): seq[GitFileChange] =
  let (output, exitCode) = execGitCommand(["status", "--short"], path)
  if exitCode != 0: return
  for line in splitLines(output):
    if line.len < 3: continue
    result.add(GitFileChange(
      path: line[3..^1].strip(),
      stagedStatus: charToStatus(line[0]),
      workingStatus: charToStatus(line[1])
    ))

proc parseGitNumstat*(path: string; cached: bool = false): Table[string, tuple[added: int, removed: int]] =
  result = initTable[string, tuple[added: int, removed: int]]()
  var args = @["diff", "--numstat"]
  if cached: args.add("--cached")
  let (output, exitCode) = execGitCommand(args, path)
  if exitCode != 0: return
  for line in splitLines(output):
    let parts = line.splitWhitespace()
    if parts.len >= 3:
      try:
        result[parts[2..^1].join(" ")] = (
          added: if parts[0] == "-": 0 else: parseInt(parts[0]),
          removed: if parts[1] == "-": 0 else: parseInt(parts[1])
        )
      except: discard

proc listBranches*(path: string): seq[string] =
  let (output, exitCode) = execGitCommand(
    ["branch", "--format=%(refname:short)"], path)
  if exitCode != 0: return
  for line in output.splitLines():
    let b = line.strip()
    if b.len > 0: result.add(b)

proc stageFile*(path, filePath: string): bool =
  execGitCommand(["add", filePath], path).exitCode == 0

proc stageAllChanges*(path: string): bool =
  execGitCommand(["add", "-A"], path).exitCode == 0

proc unstageFile*(path, filePath: string): bool =
  execGitCommand(["reset", "HEAD", filePath], path).exitCode == 0

proc commitChanges*(path, message: string): bool =
  if message.strip().len == 0: return false
  execGitCommand(["commit", "-m", message], path).exitCode == 0

proc discardChanges*(path, filePath: string): bool =
  execGitCommand(["checkout", "--", filePath], path).exitCode == 0

proc checkoutBranch*(path, branch: string): bool =
  execGitCommand(["checkout", branch], path).exitCode == 0

proc addToGitignore*(repoPath, filePath: string): bool =
  let gitignorePath = repoPath / ".gitignore"
  var content = ""
  if fileExists(gitignorePath):
    content = readFile(gitignorePath)
    if content.len > 0 and not content.endsWith("\n"):
      content.add("\n")
  content.add(filePath & "\n")
  try:
    writeFile(gitignorePath, content)
    true
  except CatchableError:
    false

proc getStagedDiff*(path: string): string =
  let (output, exitCode) = execGitCommand(["diff", "--cached", "--no-color"], path)
  if exitCode == 0: output else: ""

proc getUnstagedDiff*(path: string): string =
  let (output, exitCode) = execGitCommand(["diff", "--no-color"], path)
  if exitCode == 0: output else: ""

proc getAllLocalDiff*(path: string): string =
  let (output, exitCode) = execGitCommand(["diff", "HEAD", "--no-color"], path)
  if exitCode == 0: output else: ""

proc getFileDiff*(path, filePath: string; staged: bool = false): string =
  ## Get diff for a single file (staged or unstaged).
  var args = @["diff", "--no-color"]
  if staged: args.add("--cached")
  args.add("--")
  args.add(filePath)
  let (output, exitCode) = execGitCommand(args, path)
  if exitCode == 0: output else: ""



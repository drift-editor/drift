## Diff Engine — Line-level diff with character-level refinement
## Uses DP-based LCS for reliability; fast enough for typical file sizes.

import std/strutils

type
  DiffOpKind* = enum
    dokEqual
    dokDelete
    dokInsert
    dokReplace

  DiffOp* = object
    kind*: DiffOpKind
    oldLine*: int      ## 0-based line index in old text, -1 if not applicable
    newLine*: int      ## 0-based line index in new text, -1 if not applicable
    oldText*: string
    newText*: string
    ## For replace ops, character-level edits within the line
    charEdits*: seq[CharEdit]

  CharEdit* = object
    kind*: DiffOpKind  ## dokEqual, dokDelete, dokInsert
    oldStart*: int
    oldLen*: int
    newStart*: int
    newLen*: int

proc lcsTable(a, b: seq[string]): seq[seq[int]] =
  ## Build LCS length table using DP. O(N*M) time, O(N*M) space.
  let n = a.len
  let m = b.len
  result = newSeq[seq[int]](n + 1)
  for i in 0 .. n:
    result[i] = newSeq[int](m + 1)
  for i in 1 .. n:
    for j in 1 .. m:
      if a[i - 1] == b[j - 1]:
        result[i][j] = result[i - 1][j - 1] + 1
      else:
        result[i][j] = max(result[i - 1][j], result[i][j - 1])

proc backtrackLcs(a, b: seq[string], dp: seq[seq[int]]): seq[DiffOp] =
  ## Backtrack through the DP table to reconstruct the diff.
  var i = a.len
  var j = b.len
  var ops: seq[DiffOp] = @[]

  while i > 0 or j > 0:
    if i > 0 and j > 0 and a[i - 1] == b[j - 1]:
      # Equal line
      ops.add(DiffOp(kind: dokEqual, oldLine: i - 1, newLine: j - 1,
                     oldText: a[i - 1], newText: b[j - 1]))
      i -= 1
      j -= 1
    elif j > 0 and (i == 0 or dp[i][j - 1] >= dp[i - 1][j]):
      # Insertion (from b)
      ops.add(DiffOp(kind: dokInsert, oldLine: -1, newLine: j - 1,
                     newText: b[j - 1]))
      j -= 1
    else:
      # Deletion (from a)
      ops.add(DiffOp(kind: dokDelete, oldLine: i - 1, newLine: -1,
                     oldText: a[i - 1]))
      i -= 1

  # Reverse to get correct order
  for k in countdown(ops.high, 0):
    result.add(ops[k])

const
  MaxDiffLines* = 2000  ## Maximum lines per side before falling back to simple diff
  MaxDiffCells* = 4_000_000  ## Maximum DP table cells (oldLines * newLines)

proc lineByLineDiff(oldLines, newLines: seq[string]): seq[DiffOp] =
  ## Fallback diff: compare line-by-line for the overlapping region.
  let minLen = min(oldLines.len, newLines.len)
  for i in 0 ..< minLen:
    if oldLines[i] == newLines[i]:
      result.add(DiffOp(kind: dokEqual, oldLine: i, newLine: i,
                        oldText: oldLines[i], newText: newLines[i]))
    else:
      result.add(DiffOp(kind: dokReplace, oldLine: i, newLine: i,
                        oldText: oldLines[i], newText: newLines[i]))
  for i in minLen ..< oldLines.len:
    result.add(DiffOp(kind: dokDelete, oldLine: i, newLine: -1,
                      oldText: oldLines[i], newText: ""))
  for i in minLen ..< newLines.len:
    result.add(DiffOp(kind: dokInsert, oldLine: -1, newLine: i,
                      oldText: "", newText: newLines[i]))

proc prefixSuffixDiff(oldLines, newLines: seq[string]): seq[DiffOp] =
  ## Find common prefix and suffix, then diff the middle with DP.
  let n = oldLines.len
  let m = newLines.len
  var prefixLen = 0
  while prefixLen < n and prefixLen < m and oldLines[prefixLen] == newLines[prefixLen]:
    inc prefixLen
  var suffixLen = 0
  while suffixLen < n - prefixLen and suffixLen < m - prefixLen and
        oldLines[n - 1 - suffixLen] == newLines[m - 1 - suffixLen]:
    inc suffixLen

  # Add prefix equal ops
  for i in 0 ..< prefixLen:
    result.add(DiffOp(kind: dokEqual, oldLine: i, newLine: i,
                      oldText: oldLines[i], newText: newLines[i]))

  # Diff the middle region
  let oldMid = oldLines[prefixLen ..< n - suffixLen]
  let newMid = newLines[prefixLen ..< m - suffixLen]
  let midN = oldMid.len
  let midM = newMid.len

  var midOps: seq[DiffOp]
  if midN == 0 and midM == 0:
    discard
  elif midN <= MaxDiffLines and midM <= MaxDiffLines and midN * midM <= MaxDiffCells:
    let dp = lcsTable(oldMid, newMid)
    midOps = backtrackLcs(oldMid, newMid, dp)
  else:
    midOps = lineByLineDiff(oldMid, newMid)

  for op in midOps:
    var shifted = op
    shifted.oldLine = if op.oldLine >= 0: op.oldLine + prefixLen else: -1
    shifted.newLine = if op.newLine >= 0: op.newLine + prefixLen else: -1
    result.add(shifted)

  # Add suffix equal ops
  for i in 0 ..< suffixLen:
    result.add(DiffOp(kind: dokEqual, oldLine: n - suffixLen + i, newLine: m - suffixLen + i,
                      oldText: oldLines[n - suffixLen + i], newText: newLines[m - suffixLen + i]))

proc myersDiff*(oldLines, newLines: seq[string]): seq[DiffOp] =
  ## Compute line-level diff between two sequences of strings.
  ## Falls back to prefix/suffix extraction for very large inputs.
  let n = oldLines.len
  let m = newLines.len
  if n <= MaxDiffLines and m <= MaxDiffLines and n * m <= MaxDiffCells:
    let dp = lcsTable(oldLines, newLines)
    result = backtrackLcs(oldLines, newLines, dp)
  else:
    result = prefixSuffixDiff(oldLines, newLines)

proc computeCharEdits*(oldText, newText: string): seq[CharEdit] =
  ## Compute character-level diff between two strings using DP-based LCS.
  let n = oldText.len
  let m = newText.len
  if n == 0 and m == 0: return @[]

  # Build LCS table for characters
  var dp = newSeq[seq[int]](n + 1)
  for i in 0 .. n:
    dp[i] = newSeq[int](m + 1)
  for i in 1 .. n:
    for j in 1 .. m:
      if oldText[i - 1] == newText[j - 1]:
        dp[i][j] = dp[i - 1][j - 1] + 1
      else:
        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])

  # Backtrack
  var i = n
  var j = m
  var edits: seq[CharEdit] = @[]

  while i > 0 or j > 0:
    if i > 0 and j > 0 and oldText[i - 1] == newText[j - 1]:
      edits.add(CharEdit(kind: dokEqual, oldStart: i - 1, oldLen: 1,
                         newStart: j - 1, newLen: 1))
      i -= 1
      j -= 1
    elif j > 0 and (i == 0 or dp[i][j - 1] >= dp[i - 1][j]):
      edits.add(CharEdit(kind: dokInsert, oldStart: i, oldLen: 0,
                         newStart: j - 1, newLen: 1))
      j -= 1
    else:
      edits.add(CharEdit(kind: dokDelete, oldStart: i - 1, oldLen: 1,
                         newStart: j, newLen: 0))
      i -= 1

  # Merge consecutive edits of the same kind
  if edits.len == 0: return @[]
  var merged: seq[CharEdit] = @[edits[edits.high]]
  for k in countdown(edits.high - 1, 0):
    let last = merged[^1]
    if edits[k].kind == last.kind:
      case edits[k].kind
      of dokEqual:
        merged[^1].oldStart = edits[k].oldStart
        merged[^1].oldLen += 1
        merged[^1].newStart = edits[k].newStart
        merged[^1].newLen += 1
      of dokDelete:
        merged[^1].oldStart = edits[k].oldStart
        merged[^1].oldLen += 1
      of dokInsert:
        merged[^1].newStart = edits[k].newStart
        merged[^1].newLen += 1
      else: discard
    else:
      merged.add(edits[k])

  for k in countdown(merged.high, 0):
    result.add(merged[k])

proc refineReplacements*(ops: seq[DiffOp]): seq[DiffOp] =
  ## Convert adjacent delete+insert pairs into replace ops with character-level edits.
  var i = 0
  while i < ops.len:
    if i + 1 < ops.len and ops[i].kind == dokDelete and ops[i + 1].kind == dokInsert:
      let delOp = ops[i]
      let insOp = ops[i + 1]
      let charEdits = computeCharEdits(delOp.oldText, insOp.newText)
      result.add(DiffOp(
        kind: dokReplace,
        oldLine: delOp.oldLine,
        newLine: insOp.newLine,
        oldText: delOp.oldText,
        newText: insOp.newText,
        charEdits: charEdits
      ))
      i += 2
    else:
      result.add(ops[i])
      i += 1

proc diffText*(oldText, newText: string): seq[DiffOp] =
  ## High-level API: diff two text strings and return operations.
  ## Adjacent delete+insert pairs are merged into replace ops with char-level edits.
  let oldLines = oldText.splitLines()
  let newLines = newText.splitLines()
  result = refineReplacements(myersDiff(oldLines, newLines))

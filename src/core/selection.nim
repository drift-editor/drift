## Selection Module
## Selection management and operations

import std/[algorithm, options, strutils]
import types, errors

# Construction

proc newSelection*(anchor, caret: CursorPos, active: bool = true): Selection =
  Selection(anchor: anchor, caret: caret, active: active)

proc emptySelection*(pos: CursorPos): Selection =
  Selection(anchor: pos, caret: pos, active: false)

# Queries

proc isEmpty*(sel: Selection): bool =
  sel.anchor == sel.caret

proc normalized*(sel: Selection): tuple[start, finish: CursorPos] =
  ## Return selection in order (start <= finish)
  if sel.caret < sel.anchor:
    (sel.caret, sel.anchor)
  else:
    (sel.anchor, sel.caret)

proc contains*(sel: Selection, pos: CursorPos): bool =
  if not sel.active:
    return false
  let (start, finish) = sel.normalized()
  pos >= start and pos <= finish

proc containsLine*(sel: Selection, lineNum: int): bool =
  if not sel.active:
    return false
  let (start, finish) = sel.normalized()
  lineNum >= start.line and lineNum <= finish.line

proc startLine*(sel: Selection): int =
  min(sel.anchor.line, sel.caret.line)

proc endLine*(sel: Selection): int =
  max(sel.anchor.line, sel.caret.line)

proc getSelectedText*(sel: Selection, lines: seq[string]): string =
  ## Extract selected text from document lines
  if not sel.active or sel.isEmpty:
    return ""
  
  let (start, finish) = sel.normalized()
  
  if start.line == finish.line:
    # Single line selection
    if start.line >= 0 and start.line < lines.len:
      let line = lines[start.line]
      if start.col <= line.len and finish.col <= line.len:
        return line[start.col ..< finish.col]
    return ""
  
  # Multi-line selection
  var selectedText = ""
  for lineNum in start.line .. finish.line:
    if lineNum < 0 or lineNum >= lines.len:
      continue
    
    let line = lines[lineNum]
    if lineNum == start.line:
      # First line - from start column to end
      if start.col <= line.len:
        selectedText.add(line[start.col .. ^1])
    elif lineNum == finish.line:
      # Last line - from beginning to end column
      if finish.col <= line.len:
        selectedText.add(line[0 ..< finish.col])
    else:
      # Middle lines - entire line
      selectedText.add(line)
    
    if lineNum < finish.line:
      selectedText.add("\n")
  
  selectedText

# Modification

proc extendTo*(sel: var Selection, pos: CursorPos) =
  ## Extend selection to new position
  sel.caret = pos
  sel.active = true

proc setAnchor*(sel: var Selection, pos: CursorPos) =
  ## Set selection anchor
  sel.anchor = pos
  sel.active = true

proc collapseTo*(sel: var Selection, pos: CursorPos) =
  ## Collapse selection to single position
  sel.anchor = pos
  sel.caret = pos
  sel.active = false

proc collapseToStart*(sel: var Selection) =
  let (start, _) = sel.normalized()
  sel.collapseTo(start)

proc collapseToEnd*(sel: var Selection) =
  let (_, finish) = sel.normalized()
  sel.collapseTo(finish)

proc selectAll*(sel: var Selection, lineCount: int, getLineLen: proc(line: int): int) =
  ## Select entire document
  if lineCount == 0:
    sel.collapseTo(CursorPos(line: 0, col: 0))
    return
  
  let lastLine = lineCount - 1
  let lastCol = getLineLen(lastLine)
  
  sel.anchor = CursorPos(line: 0, col: 0)
  sel.caret = CursorPos(line: lastLine, col: lastCol)
  sel.active = true

proc selectLine*(sel: var Selection, lineNum: int, getLineLen: proc(line: int): int) =
  ## Select entire line (without line ending)
  let lineLen = getLineLen(lineNum)
  sel.anchor = CursorPos(line: lineNum, col: 0)
  sel.caret = CursorPos(line: lineNum, col: lineLen)
  sel.active = true

proc selectWordAt*(sel: var Selection, pos: CursorPos, lines: seq[string]) =
  ## Select word at position
  if pos.line < 0 or pos.line >= lines.len:
    return
  
  let line = lines[pos.line]
  if pos.col < 0 or pos.col > line.len:
    return
  
  const WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  
  var startCol = pos.col
  var endCol = pos.col
  
  # Go backwards
  while startCol > 0 and line[startCol - 1] in WordChars:
    startCol.dec()
  
  # Go forwards
  while endCol < line.len and line[endCol] in WordChars:
    endCol.inc()
  
  sel.anchor = CursorPos(line: pos.line, col: startCol)
  sel.caret = CursorPos(line: pos.line, col: endCol)
  sel.active = true

# Multi-Selection Support

type
  MultiSelection* = ref object
    selections*: seq[Selection]
    primaryIndex*: int

proc newMultiSelection*(): MultiSelection =
  MultiSelection(selections: @[], primaryIndex: -1)

proc isEmpty*(ms: MultiSelection): bool =
  ms.selections.len == 0 or (ms.selections.len == 1 and ms.selections[0].isEmpty)

proc primary*(ms: MultiSelection): Option[Selection] =
  if ms.primaryIndex >= 0 and ms.primaryIndex < ms.selections.len:
    some(ms.selections[ms.primaryIndex])
  else:
    none(Selection)

proc addSelection*(ms: MultiSelection, sel: Selection) =
  ms.selections.add(sel)
  if ms.primaryIndex < 0:
    ms.primaryIndex = 0

proc clear*(ms: MultiSelection) =
  ms.selections.setLen(0)
  ms.primaryIndex = -1

proc collapseToPrimary*(ms: MultiSelection) =
  if ms.primaryIndex >= 0 and ms.primaryIndex < ms.selections.len:
    let primary = ms.selections[ms.primaryIndex]
    ms.selections = @[primary]
    ms.primaryIndex = 0

## History Module
## Undo/Redo system with grouping support

import std/[times, sequtils]
import types, document
import ../utils/text

type
  HistoryGroup* = object
    edits*: seq[TextEdit]
    description*: string
    timestamp*: float64
  
  History* = ref object
    groups*: seq[HistoryGroup]
    currentIndex*: int      # Index of last applied group (-1 = none)
    maxGroups*: int
    isUndoing*: bool        # Flag to prevent recording during undo/redo
    lastSaveIndex*: int     # Index at last save (-1 = never saved)

proc newHistory*(maxGroups: int = 100): History =
  History(
    groups: @[],
    currentIndex: -1,
    maxGroups: maxGroups,
    isUndoing: false,
    lastSaveIndex: -1
  )

# Basic Operations

proc clear*(history: History) =
  history.groups.setLen(0)
  history.currentIndex = -1
  history.lastSaveIndex = -1

proc canUndo*(history: History): bool =
  history.currentIndex >= 0

proc canRedo*(history: History): bool =
  history.currentIndex < history.groups.high

proc isModified*(history: History): bool =
  ## Check if document has been modified since last save
  if history.lastSaveIndex < 0:
    history.currentIndex >= 0
  else:
    history.currentIndex != history.lastSaveIndex

# Edit Recording

proc beginGroup*(history: History, description: string = "") =
  ## Start a new edit group
  if history.isUndoing:
    return
  
  # Remove any groups after current index (redo history)
  if history.currentIndex < history.groups.high:
    history.groups.setLen(history.currentIndex + 1)
  
  # Create new group
  let group = HistoryGroup(
    edits: @[],
    description: description,
    timestamp: epochTime()
  )
  
  history.groups.add(group)
  history.currentIndex.inc()
  
  # Trim if exceeds max
  if history.groups.len > history.maxGroups:
    let removed = history.groups.len - history.maxGroups
    history.groups.delete(0 ..< removed)
    history.currentIndex -= removed
    if history.lastSaveIndex >= 0:
      history.lastSaveIndex -= removed

proc endGroup*(history: History) =
  ## End current edit group
  discard

proc push*(history: History, edit: TextEdit) =
  ## Add an edit to the current group
  if history.isUndoing:
    return
  
  # Auto-begin group if none active
  if history.currentIndex < 0 or history.currentIndex >= history.groups.len:
    history.beginGroup()
  
  history.groups[history.currentIndex].edits.add(edit)

proc pushSimple*(history: History, edit: TextEdit, description: string = "") =
  ## Push a single edit as its own group
  if history.isUndoing:
    return
  
  history.beginGroup(description)
  history.push(edit)

# Undo/Redo Operations

proc undo*(history: History, doc: Document): bool =
  ## Undo one group of edits. Returns true if successful.
  if not history.canUndo:
    return false
  
  let group = history.groups[history.currentIndex]
  if group.edits.len == 0:
    history.currentIndex.dec()
    return true
  
  history.isUndoing = true
  defer: history.isUndoing = false
  
  # Apply edits in reverse order
  for i in countdown(group.edits.high, 0):
    let edit = group.edits[i]
    
    case edit.operation
    of eoInsert:
      # Undo insert = delete
      let nlines = edit.content.lineCount()
      let endLine = edit.position.line + nlines - 1
      let endCol = if nlines == 1:
        edit.position.col + edit.content.len
      else:
        edit.content.lastLineLen + edit.position.col
      let endPos = CursorPos(line: endLine, col: endCol)
      
      # Delete without recording to history
      let wasModified = doc.isModified
      let delResult = doc.deleteRange(edit.position, endPos)
      if delResult.isOk and doc.undoStack.len > 0:
        doc.undoStack.del(doc.undoStack.high)  # Remove the undo record
      doc.isModified = wasModified
    
    of eoDelete:
      # Undo delete = insert
      let wasModified = doc.isModified
      let insResult = doc.insertText(edit.position, edit.previousContent)
      if insResult.isOk and doc.undoStack.len > 0:
        doc.undoStack.del(doc.undoStack.high)
      doc.isModified = wasModified
    
    of eoReplace:
      # Undo replace = restore old content
      let nlines = edit.content.lineCount()
      let endLine = edit.position.line + nlines - 1
      let endCol = if nlines == 1:
        edit.position.col + edit.content.len
      else:
        edit.content.lastLineLen + edit.position.col
      let endPos = CursorPos(line: endLine, col: endCol)
      
      let wasModified = doc.isModified
      let delResult = doc.deleteRange(edit.position, endPos)
      if delResult.isOk and doc.undoStack.len > 0:
        doc.undoStack.del(doc.undoStack.high)

      let insResult = doc.insertText(edit.position, edit.previousContent)
      if insResult.isOk and doc.undoStack.len > 0:
        doc.undoStack.del(doc.undoStack.high)
      doc.isModified = wasModified
  
  history.currentIndex.dec()
  true

proc redo*(history: History, doc: Document): bool =
  ## Redo one group of edits. Returns true if successful.
  if not history.canRedo:
    return false
  
  let nextIndex = history.currentIndex + 1
  let group = history.groups[nextIndex]
  if group.edits.len == 0:
    history.currentIndex = nextIndex
    return true
  
  history.isUndoing = true
  defer: history.isUndoing = false
  
  # Apply edits in forward order
  for edit in group.edits:
    let wasModified = doc.isModified
    
    case edit.operation
    of eoInsert:
      let insResult = doc.insertText(edit.position, edit.content)
      if insResult.isOk and doc.undoStack.len > 0:
        doc.undoStack.del(doc.undoStack.high)
    of eoDelete:
      let nlines = edit.previousContent.lineCount()
      let endLine = edit.position.line + nlines - 1
      let endCol = if nlines == 1:
        edit.position.col + edit.previousContent.len
      else:
        edit.previousContent.lastLineLen + edit.position.col
      let endPos = CursorPos(line: endLine, col: endCol)
      let delResult = doc.deleteRange(edit.position, endPos)
      if delResult.isOk and doc.undoStack.len > 0:
        doc.undoStack.del(doc.undoStack.high)
    of eoReplace:
      let repResult = doc.replaceRange(edit.position, edit.position, edit.content)
      if repResult.isOk:
        if doc.undoStack.len >= 2:
          doc.undoStack.del(doc.undoStack.high)
          doc.undoStack.del(doc.undoStack.high)
    
    doc.isModified = wasModified
  
  history.currentIndex = nextIndex
  true

# Save Point Management

proc markSaved*(history: History) =
  ## Mark current state as saved
  history.lastSaveIndex = history.currentIndex

proc revertToSave*(history: History, doc: Document): bool =
  ## Revert to last saved state
  if not history.isModified:
    return true
  
  # Undo until we reach save point
  while history.currentIndex > history.lastSaveIndex and history.canUndo:
    discard history.undo(doc)
  
  # Or redo if we undid past the save point
  while history.currentIndex < history.lastSaveIndex and history.canRedo:
    discard history.redo(doc)
  
  history.lastSaveIndex == history.currentIndex

# Group Information

proc getCurrentDescription*(history: History): string =
  if history.currentIndex >= 0 and history.currentIndex < history.groups.len:
    history.groups[history.currentIndex].description
  else:
    ""

proc getUndoDescription*(history: History): string =
  if history.canUndo:
    history.groups[history.currentIndex].description
  else:
    ""

proc getRedoDescription*(history: History): string =
  if history.canRedo:
    history.groups[history.currentIndex + 1].description
  else:
    ""

proc getHistorySize*(history: History): tuple[undo, redo: int] =
  (history.currentIndex + 1, history.groups.len - history.currentIndex - 1)

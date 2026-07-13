## Document Model
## Pure text document operations, no external dependencies

import std/[strutils, algorithm, unicode, times, strformat]
import types, errors
import ../utils/text
export errors.Result, errors.ok, errors.err, errors.isOk, errors.isErr

# Construction

proc newDocument*(content: string = "", metadata: DocumentMetadata = defaultMetadata()): Document =
  let lines = if content.len == 0:
    @[""]
  else:
    content.splitLinesKeep()
  
  Document(
    lines: lines,
    metadata: metadata,
    undoStack: @[],
    redoStack: @[],
    maxUndoSize: 1000,
    isModified: false,
    version: 0,
    hasTrailingNewline: content.len > 0 and content[^1] == '\n'
  )

proc newDocumentFromLines*(lines: seq[string], metadata: DocumentMetadata = defaultMetadata()): Document =
  Document(
    lines: lines,
    metadata: metadata,
    undoStack: @[],
    redoStack: @[],
    maxUndoSize: 1000,
    isModified: false,
    version: 0
  )

# Queries

proc lineCount*(doc: Document): int = doc.lines.len

proc totalLength*(doc: Document): int =
  var total = 0
  for line in doc.lines:
    total += line.len
  total + (doc.lines.len - 1) * (
    case doc.metadata.lineEnding
    of leLf: 1
    of leCrLf: 2
    of leCr: 1
  )

proc isEmpty*(doc: Document): bool =
  doc.lines.len == 1 and doc.lines[0].len == 0

proc lineLength*(doc: Document, lineNum: int): int =
  if lineNum >= 0 and lineNum < doc.lines.len:
    doc.lines[lineNum].len
  else:
    0

proc getLine*(doc: Document, lineNum: int): Result[string] =
  if lineNum < 0 or lineNum >= doc.lines.len:
    return err[string](newError(ecLineOutOfBounds, &"Line {lineNum} out of bounds (0..{doc.lines.len-1})"))
  ok(doc.lines[lineNum])

proc isValidPosition*(doc: Document, pos: CursorPos): bool =
  pos.line >= 0 and pos.line < doc.lines.len and
  pos.col >= 0 and pos.col <= doc.lineLength(pos.line)

proc getTextRange*(doc: Document, start, finish: CursorPos): Result[string] =
  if not doc.isValidPosition(start) or not doc.isValidPosition(finish):
    return err[string](invalidPosition((start, finish)))
  
  let (s, f) = if finish < start: (finish, start) else: (start, finish)
  
  if s.line == f.line:
    # Single line selection
    let line = doc.lines[s.line]
    if s.col <= f.col and f.col <= line.len:
      return ok(line[s.col ..< f.col])
    return err[string](invalidRange("Column out of bounds"))
  
  # Multi-line selection
  var textResult = ""
  let lineEnding = case doc.metadata.lineEnding
    of leLf: "\n"
    of leCrLf: "\r\n"
    of leCr: "\r"
  
  for lineNum in s.line .. f.line:
    if lineNum == s.line:
      textResult.add(doc.lines[lineNum][s.col .. ^1])
    elif lineNum == f.line:
      textResult.add(doc.lines[lineNum][0 ..< f.col])
    else:
      textResult.add(doc.lines[lineNum])
    
    if lineNum < f.line:
      textResult.add(lineEnding)
  
  ok(textResult)

proc getFullText*(doc: Document): string =
  let sep = case doc.metadata.lineEnding
    of leLf: "\n"
    of leCrLf: "\r\n"
    of leCr: "\r"
  result = doc.lines.join(sep)

proc getCharacterCount*(doc: Document): int =
  var count = 0
  for line in doc.lines:
    count += line.len
  count

proc getWordCount*(doc: Document): int =
  let text = doc.getFullText()
  var count = 0
  var inWord = false
  for c in text:
    if c.isAlphaNumeric:
      if not inWord:
        count.inc()
        inWord = true
    else:
      inWord = false
  count

# Editing Operations

proc pushUndo*(doc: Document, edit: TextEdit) =
  doc.undoStack.add(edit)
  if doc.undoStack.len > doc.maxUndoSize:
    doc.undoStack.delete(0)
  doc.redoStack.setLen(0)  # Clear redo stack on new edit
  doc.isModified = true
  doc.version.inc()

proc insertText*(doc: Document, pos: CursorPos, text: string): Result[CursorPos] =
  if not doc.isValidPosition(pos):
    return err[CursorPos](invalidPosition(pos))
  
  let lines = text.splitLinesKeep()
  let originalLine = doc.lines[pos.line]
  
  # Create undo record
  let undoEdit = TextEdit(
    operation: eoDelete,
    position: pos,
    content: text,
    previousContent: ""
  )
  
  if lines.len == 1:
    # Single line insertion
    doc.lines[pos.line] = originalLine[0 ..< pos.col] & text & originalLine[pos.col .. ^1]
    let newPos = CursorPos(line: pos.line, col: pos.col + text.len)
    doc.pushUndo(undoEdit)
    return ok(newPos)
  else:
    # Multi-line insertion
    let firstPart = originalLine[0 ..< pos.col]
    let lastPart = originalLine[pos.col .. ^1]
    
    # Replace current line with first part + first new line
    doc.lines[pos.line] = firstPart & lines[0]
    
    # Insert middle lines
    for i in 1 ..< lines.len - 1:
      doc.lines.insert(lines[i], pos.line + i)
    
    # Insert last line + last part
    doc.lines.insert(lines[^1] & lastPart, pos.line + lines.len - 1)
    
    let newPos = CursorPos(
      line: pos.line + lines.len - 1,
      col: lines[^1].len
    )
    doc.pushUndo(undoEdit)
    return ok(newPos)

proc deleteRange*(doc: Document, start, finish: CursorPos): Result[string] =
  ## Delete text between two positions and return the deleted text
  if not doc.isValidPosition(start) or not doc.isValidPosition(finish):
    return err[string](invalidPosition((start, finish)))
  
  let (s, f) = if finish < start: (finish, start) else: (start, finish)
  
  # Get the text that will be deleted for undo
  let deletedTextResult = doc.getTextRange(s, f)
  if deletedTextResult.isErr:
    return err[string](deletedTextResult.error)
  let deletedText = deletedTextResult.value
  
  # Create undo record
  let undoEdit = TextEdit(
    operation: eoInsert,
    position: s,
    content: "",
    previousContent: deletedText
  )
  
  if s.line == f.line:
    # Single line delete
    let line = doc.lines[s.line]
    doc.lines[s.line] = line[0 ..< s.col] & line[f.col .. ^1]
  else:
    # Multi-line delete
    let firstLine = doc.lines[s.line]
    let lastLine = doc.lines[f.line]
    doc.lines[s.line] = firstLine[0 ..< s.col] & lastLine[f.col .. ^1]
    # Delete lines in reverse order to maintain correct indices
    for i in countdown(f.line, s.line + 1):
      doc.lines.delete(i)
  
  doc.pushUndo(undoEdit)
  ok(deletedText)

proc replaceRange*(doc: Document, start, finish: CursorPos, text: string): Result[CursorPos] =
  ## Replace text between two positions with new text
  let deletedTextResult = doc.deleteRange(start, finish)
  if deletedTextResult.isErr:
    return err[CursorPos](deletedTextResult.error)
  
  let insertResult = doc.insertText(start, text)
  if insertResult.isErr:
    return err[CursorPos](insertResult.error)
  
  # Update undo record to be a replace operation
  if doc.undoStack.len > 0:
    doc.undoStack[^1].operation = eoReplace
    doc.undoStack[^1].previousContent = deletedTextResult.value
  
  ok(insertResult.value)

proc insertLine*(doc: Document, lineNum: int, content: string = ""): Result[bool] =
  if lineNum < 0 or lineNum > doc.lines.len:
    return err[bool](invalidPosition(CursorPos(line: lineNum, col: 0)))
  
  doc.lines.insert(content, lineNum)
  doc.isModified = true
  doc.version.inc()
  ok(true)

proc deleteLine*(doc: Document, lineNum: int): Result[string] =
  if lineNum < 0 or lineNum >= doc.lines.len:
    return err[string](newError(ecLineOutOfBounds, &"Cannot delete line {lineNum}"))
  
  let content = doc.lines[lineNum]
  doc.lines.delete(lineNum)
  
  # Ensure document always has at least one line
  if doc.lines.len == 0:
    doc.lines.add("")
  
  doc.isModified = true
  doc.version.inc()
  ok(content)

# Undo/Redo

proc canUndo*(doc: Document): bool = doc.undoStack.len > 0
proc canRedo*(doc: Document): bool = doc.redoStack.len > 0

proc undo*(doc: Document): Result[CursorPos] =
  if not doc.canUndo:
    return err[CursorPos](newError(ecInvalidState, "Nothing to undo"))
  
  let edit = doc.undoStack.pop()
  
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
    let delResult = doc.deleteRange(edit.position, endPos)
    if delResult.isOk and doc.undoStack.len > 0:
      doc.undoStack.del(doc.undoStack.high)
  
  of eoDelete:
    # Undo delete = insert
    let insResult = doc.insertText(edit.position, edit.previousContent)
    if insResult.isOk and doc.undoStack.len > 0:
      doc.undoStack.del(doc.undoStack.high)
  
  of eoReplace:
    # Undo replace = restore old content
    let nlines = edit.content.lineCount()
    let endLine = edit.position.line + nlines - 1
    let endCol = if nlines == 1:
      edit.position.col + edit.content.len
    else:
      edit.content.lastLineLen + edit.position.col
    let endPos = CursorPos(line: endLine, col: endCol)

    let delResult = doc.deleteRange(edit.position, endPos)
    if delResult.isOk and doc.undoStack.len > 0:
      doc.undoStack.del(doc.undoStack.high)

    let insResult = doc.insertText(edit.position, edit.previousContent)
    if insResult.isOk and doc.undoStack.len > 0:
      doc.undoStack.del(doc.undoStack.high)

  doc.redoStack.add(edit)
  ok(edit.position)

proc redo*(doc: Document): Result[CursorPos] =
  if not doc.canRedo:
    return err[CursorPos](newError(ecInvalidState, "Nothing to redo"))

  let edit = doc.redoStack.pop()

  case edit.operation
  of eoInsert:
    discard doc.insertText(edit.position, edit.content)
  of eoDelete:
    let nlines = edit.previousContent.lineCount()
    let endLine = edit.position.line + nlines - 1
    let endCol = if nlines == 1:
      edit.position.col + edit.previousContent.len
    else:
      edit.previousContent.lastLineLen + edit.position.col
    let endPos = CursorPos(line: endLine, col: endCol)
    discard doc.deleteRange(edit.position, endPos)
  of eoReplace:
    discard doc.replaceRange(edit.position, edit.position, edit.content)
  
  # The operation already added to undo stack
  ok(edit.position)

# Utility Operations

proc getWordAt*(doc: Document, pos: CursorPos): tuple[start, finish: CursorPos, word: string] =
  let lineResult = doc.getLine(pos.line)
  if lineResult.isErr:
    return (pos, pos, "")
  
  let line = lineResult.value
  if pos.col < 0 or pos.col > line.len:
    return (pos, pos, "")
  
  # Find word boundaries
  var startCol = pos.col
  var endCol = pos.col
  
  const WordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  
  # Go backwards
  while startCol > 0 and line[startCol - 1] in WordChars:
    startCol.dec()
  
  # Go forwards
  while endCol < line.len and line[endCol] in WordChars:
    endCol.inc()
  
  let word = line[startCol ..< endCol]
  let startPos = CursorPos(line: pos.line, col: startCol)
  let endPos = CursorPos(line: pos.line, col: endCol)
  
  (startPos, endPos, word)

proc getLineIndent*(doc: Document, lineNum: int): int =
  ## Get the indentation level of a line
  let lineResult = doc.getLine(lineNum)
  if lineResult.isErr:
    return 0
  
  let line = lineResult.value
  var indent = 0
  for c in line:
    if c == ' ':
      indent.inc()
    elif c == '\t':
      indent += doc.metadata.tabSize
    else:
      break
  indent

proc getStats*(doc: Document): DocumentStats =
  DocumentStats(
    lineCount: doc.lineCount(),
    characterCount: doc.getCharacterCount(),
    wordCount: doc.getWordCount(),
    nonWhitespaceCharCount: doc.getCharacterCount()  # TODO: subtract whitespace
  )

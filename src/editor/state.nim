## Editor State Module
## Central state management for the editor

import std/[options, tables, times, os, strutils]
import ../core/[types, document, history, errors, selection]

type
  EditorState* = ref object
    # Core document
    document*: Document
    history*: History
    
    # Cursor and selection
    cursor*: CursorPos
    selection*: Selection
    desiredColumn*: int
    
    # View state
    scrollOffset*: Vec2
    viewport*: Rect
    
    # File state
    filePath*: Option[string]
    fileName*: string
    language*: string
    
    # Config
    tabSize*: int
    useSpaces*: bool
    wordWrap*: bool
    showLineNumbers*: bool
    
    # Observers
    observers*: seq[StateObserver]
  
  StateChangeKind* = enum
    sckDocument, sckCursor, sckSelection, sckScroll, sckFile
  
  StateChange* = object
    kind*: StateChangeKind
    state*: EditorState
  
  StateObserver* = proc(change: StateChange)

# Construction

proc createEditorState*(): EditorState =
  EditorState(
    document: newDocument(),
    history: newHistory(),
    cursor: CursorPos(line: 0, col: 0),
    selection: emptySelection(CursorPos(line: 0, col: 0)),
    desiredColumn: 0,
    scrollOffset: vec2(0, 0),
    viewport: rect(0, 0, 800, 600),
    filePath: none(string),
    fileName: "untitled",
    language: "plaintext",
    tabSize: 4,
    useSpaces: true,
    wordWrap: false,
    showLineNumbers: true,
    observers: @[]
  )

# Observer Pattern

proc subscribe*(state: EditorState, observer: StateObserver) =
  state.observers.add(observer)

proc notify*(state: EditorState, kind: StateChangeKind) =
  let change = StateChange(kind: kind, state: state)
  for observer in state.observers:
    observer(change)

# Document Operations

proc loadDocument*(state: EditorState, content, path: string) =
  state.document = newDocument(content)
  state.history = newHistory()
  state.cursor = CursorPos(line: 0, col: 0)
  state.selection = emptySelection(state.cursor)
  state.desiredColumn = 0
  state.filePath = some(path)
  state.fileName = path.extractFilename()
  
  # Detect language from extension
  if "." in path:
    let ext = path.splitFile().ext.toLowerAscii()
    state.language = case ext
      of ".nim": "nim"
      of ".py": "python"
      of ".js", ".ts": "javascript"
      of ".rs": "rust"
      of ".c", ".h": "c"
      of ".cpp", ".hpp", ".cc": "cpp"
      of ".go": "go"
      of ".md": "markdown"
      else: "plaintext"
  else:
    state.language = "plaintext"
  
  state.notify(sckFile)
  state.notify(sckDocument)

proc getDocumentText*(state: EditorState): string =
  state.document.getFullText()

# Cursor Operations

proc setCursor*(state: EditorState, pos: CursorPos, extendSelection: bool = false) =
  let clampedLine = clamp(pos.line, 0, state.document.lineCount - 1)
  let lineLen = state.document.lineLength(clampedLine)
  let clampedCol = clamp(pos.col, 0, lineLen)
  let newPos = CursorPos(line: clampedLine, col: clampedCol)
  
  if extendSelection:
    state.selection.extendTo(newPos)
  else:
    state.selection.collapseTo(newPos)
  
  state.cursor = newPos
  state.desiredColumn = newPos.col
  state.notify(sckCursor)

proc moveCursor*(state: EditorState, deltaLine, deltaCol: int, extendSelection: bool = false) =
  var newLine = state.cursor.line + deltaLine
  var newCol = state.cursor.col + deltaCol
  
  if deltaLine != 0:
    newCol = state.desiredColumn
  
  state.setCursor(CursorPos(line: newLine, col: newCol), extendSelection)

proc moveCursorLine*(state: EditorState, delta: int, extendSelection: bool = false) =
  state.moveCursor(delta, 0, extendSelection)

proc moveCursorChar*(state: EditorState, delta: int, extendSelection: bool = false) =
  state.moveCursor(0, delta, extendSelection)

proc moveCursorWord*(state: EditorState, forward: bool, extendSelection: bool = false) =
  ## Move cursor to next/previous word
  if state.cursor.line < 0 or state.cursor.line >= state.document.lines.len:
    return
  let line = state.document.lines[state.cursor.line]
  var newCol = state.cursor.col
  
  if forward:
    # Skip current word
    while newCol < line.len and line[newCol] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      newCol.inc()
    # Skip whitespace
    while newCol < line.len and line[newCol] == ' ':
      newCol.inc()
  else:
    # Skip whitespace
    while newCol > 0 and line[newCol - 1] == ' ':
      newCol.dec()
    # Skip word
    while newCol > 0 and line[newCol - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      newCol.dec()
  
  state.setCursor(CursorPos(line: state.cursor.line, col: newCol), extendSelection)

proc moveCursorHome*(state: EditorState, extendSelection: bool = false) =
  state.setCursor(CursorPos(line: state.cursor.line, col: 0), extendSelection)

proc moveCursorEnd*(state: EditorState, extendSelection: bool = false) =
  let lineLen = state.document.lineLength(state.cursor.line)
  state.setCursor(CursorPos(line: state.cursor.line, col: lineLen), extendSelection)

# Text Editing

proc insertText*(state: EditorState, text: string) =
  ## Insert text at cursor position
  if state.selection.active and not selection.isEmpty(state.selection):
    let (start, finish) = selection.normalized(state.selection)
    discard state.document.deleteRange(start, finish)
    state.cursor = start
  
  let result = state.document.insertText(state.cursor, text)
  if result.isOk:
    state.cursor = result.value
    state.desiredColumn = state.cursor.col
    state.selection.collapseTo(state.cursor)
    state.notify(sckDocument)
    state.notify(sckCursor)

proc deleteSelection*(state: EditorState) =
  if not state.selection.active or selection.isEmpty(state.selection):
    return
  
  let (start, finish) = selection.normalized(state.selection)
  discard state.document.deleteRange(start, finish)
  state.cursor = start
  state.selection.collapseTo(start)
  state.desiredColumn = start.col
  state.notify(sckDocument)
  state.notify(sckCursor)

proc deleteChar*(state: EditorState, forward: bool = true) =
  if state.selection.active and not selection.isEmpty(state.selection):
    state.deleteSelection()
    return
  
  var start, finish: CursorPos
  if forward:
    start = state.cursor
    finish = CursorPos(line: state.cursor.line, col: state.cursor.col + 1)
    if finish.col > state.document.lineLength(start.line):
      if start.line < state.document.lineCount - 1:
        finish = CursorPos(line: start.line + 1, col: 0)
      else:
        return
  else:
    finish = state.cursor
    start = CursorPos(line: state.cursor.line, col: state.cursor.col - 1)
    if start.col < 0:
      if start.line > 0:
        let prevLineLen = state.document.lineLength(start.line - 1)
        start = CursorPos(line: start.line - 1, col: prevLineLen)
      else:
        return
  
  discard state.document.deleteRange(start, finish)
  state.cursor = start
  state.desiredColumn = start.col
  state.notify(sckDocument)
  state.notify(sckCursor)

proc insertNewline*(state: EditorState) =
  ## Insert newline with auto-indent
  if state.cursor.line < 0 or state.cursor.line >= state.document.lines.len:
    return
  let currentLine = state.document.lines[state.cursor.line]
  var indent = ""
  for c in currentLine:
    if c == ' ' or c == '\t':
      indent.add(c)
    else:
      break
  
  state.insertText("\n" & indent)

# Undo/Redo

proc undo*(state: EditorState): bool =
  let undoResult = state.document.undo()
  if undoResult.isOk:
    state.cursor = undoResult.value
    state.selection.collapseTo(state.cursor)
    state.notify(sckDocument)
    state.notify(sckCursor)
    true
  else:
    false

proc redo*(state: EditorState): bool =
  let redoResult = state.document.redo()
  if redoResult.isOk:
    state.cursor = redoResult.value
    state.selection.collapseTo(state.cursor)
    state.notify(sckDocument)
    state.notify(sckCursor)
    true
  else:
    false

# View Operations

proc setViewport*(state: EditorState, viewport: Rect) =
  state.viewport = viewport

proc setScrollOffset*(state: EditorState, offset: Vec2) =
  state.scrollOffset = offset
  state.notify(sckScroll)

proc ensureCursorVisible*(state: EditorState, lineHeight: float32) =
  let cursorY = float32(state.cursor.line) * lineHeight
  let viewTop = state.scrollOffset.y
  let viewBottom = viewTop + state.viewport.height
  
  if cursorY < viewTop:
    state.scrollOffset.y = cursorY
    state.notify(sckScroll)
  elif cursorY + lineHeight > viewBottom:
    state.scrollOffset.y = cursorY + lineHeight - state.viewport.height
    state.notify(sckScroll)

proc screenToPosition*(state: EditorState, screenPos: Vec2, charWidth, lineHeight: float32): CursorPos =
  let x = screenPos.x - state.viewport.x + state.scrollOffset.x
  let y = screenPos.y - state.viewport.y + state.scrollOffset.y
  
  if lineHeight <= 0.0 or charWidth <= 0.0:
    return CursorPos(line: 0, col: 0)
  
  let line = int(y / lineHeight)
  let col = int(x / charWidth)
  
  CursorPos(
    line: clamp(line, 0, state.document.lineCount - 1),
    col: clamp(col, 0, state.document.lineLength(line))
  )

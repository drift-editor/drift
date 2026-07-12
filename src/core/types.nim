## Core Types Module
## Pure Nim, zero external dependencies
## Foundation types used across all layers

import std/options

type
  ## Application Screen State
  AppScreen* = enum
    asWelcome
    asWorkspace

  ## Geometry Types (replaces raylib Vector2/Rectangle)
  
  Vec2* = object
    x*, y*: float32
  
  Vec2i* = object
    x*, y*: int
  
  Rect* = object
    x*, y*, width*, height*: float32
  
  Recti* = object
    x*, y*, width*, height*: int
  
  ## Color Type (platform-agnostic, replaces raylib Color)
  
  Color* = object
    r*, g*, b*, a*: uint8
  
  ## Editor Position Types
  
  CursorPos* = object
    line*: int      # 0-based line number
    col*: int       # 0-based column number
  
  TextRange* = object
    start*: int     # Character offset from start of document
    finish*: int
  
  LineRange* = object
    startLine*: int
    startCol*: int
    endLine*: int
    endCol*: int
  
  Selection* = object
    anchor*: CursorPos    # Selection start (doesn't move with caret)
    caret*: CursorPos     # Selection end (moves with cursor)
    active*: bool
  
  ## Editor State Types
  
  EditorMode* = enum
    emNormal      # Normal editing mode
    emInsert      # Insert mode
    emVisual      # Visual selection mode
    emCommand     # Command line mode
  
  LineEnding* = enum
    leLf          # Unix \n
    leCrLf        # Windows \r\n
    leCr          # Old Mac \r

  ## Document Types
  
  DocumentMetadata* = object
    language*: string
    encoding*: string
    tabSize*: int
    useSpaces*: bool
    lineEnding*: LineEnding
  
  EditOperation* = enum
    eoInsert = "insert"
    eoDelete = "delete"
    eoReplace = "replace"
  
  TextEdit* = object
    operation*: EditOperation
    position*: CursorPos
    content*: string
    previousContent*: string
  
  Document* = ref object
    lines*: seq[string]
    metadata*: DocumentMetadata
    undoStack*: seq[TextEdit]
    redoStack*: seq[TextEdit]
    maxUndoSize*: int
    isModified*: bool
    version*: int
    hasTrailingNewline*: bool
  
  DocumentStats* = object
    lineCount*: int
    characterCount*: int
    wordCount*: int
    nonWhitespaceCharCount*: int
  
  ## LSP Types
  
  LSPPosition* = object
    line*: int
    character*: int
  
  LSPRange* = object
    start*: LSPPosition
    `end`*: LSPPosition
  
  HoverInfo* = object
    content*: string
    range*: Option[LSPRange]

  Location* = object
    uri*: string
    range*: LSPRange
  
  ## UI Types
  
  NotificationType* = enum
    ntInfo = "info"
    ntWarning = "warning"
    ntError = "error"
    ntSuccess = "success"
  
  SidebarPanel* = enum
    spExplorer = "explorer"
    spSearch = "search"
    spGit = "git"
    spExtensions = "extensions"
  
  ## Syntax Highlighting Types
  
  HighlightTokenType* = enum
    ttKeyword = "keyword"
    ttIdentifier = "identifier"
    ttString = "string"
    ttNumber = "number"
    ttComment = "comment"
    ttOperator = "operator"
    ttPunctuation = "punctuation"
    ttType = "type"
    ttFunction = "function"
    ttVariable = "variable"
    ttWhitespace = "whitespace"
    ttUnknown = "unknown"
  
  HighlightToken* = object
    tokenType*: HighlightTokenType
    start*: int
    length*: int
    line*: int
  
  SyntaxHighlighter* = ref object
    language*: string
    tokens*: seq[HighlightToken]

  ## File Types
  
  FileType* = enum
    ftText = "text"
    ftBinary = "binary"
    ftUnknown = "unknown"
  
  FileInfo* = object
    name*: string
    path*: string
    isDirectory*: bool
    size*: int64
    modified*: float64

# Color Constants

const
  Transparent* = Color(r: 0, g: 0, b: 0, a: 0)
  Black* = Color(r: 0, g: 0, b: 0, a: 255)
  White* = Color(r: 255, g: 255, b: 255, a: 255)
  Red* = Color(r: 255, g: 0, b: 0, a: 255)
  Green* = Color(r: 0, g: 255, b: 0, a: 255)
  Blue* = Color(r: 0, g: 0, b: 255, a: 255)
  Yellow* = Color(r: 255, g: 255, b: 0, a: 255)
  Cyan* = Color(r: 0, g: 255, b: 255, a: 255)
  Magenta* = Color(r: 255, g: 0, b: 255, a: 255)
  Gray* = Color(r: 128, g: 128, b: 128, a: 255)
  DarkGray* = Color(r: 64, g: 64, b: 64, a: 255)
  LightGray* = Color(r: 192, g: 192, b: 192, a: 255)

# Geometry Operations

proc vec2*(x, y: float32): Vec2 = Vec2(x: x, y: y)
proc vec2i*(x, y: int): Vec2i = Vec2i(x: x, y: y)
proc rect*(x, y, w, h: float32): Rect = Rect(x: x, y: y, width: w, height: h)
proc recti*(x, y, w, h: int): Recti = Recti(x: x, y: y, width: w, height: h)

proc `+`*(a, b: Vec2): Vec2 = vec2(a.x + b.x, a.y + b.y)
proc `-`*(a, b: Vec2): Vec2 = vec2(a.x - b.x, a.y - b.y)
proc `*`*(v: Vec2, s: float32): Vec2 = vec2(v.x * s, v.y * s)
proc `/`*(v: Vec2, s: float32): Vec2 =
  if s == 0.0: return vec2(0, 0)
  vec2(v.x / s, v.y / s)

proc contains*(r: Rect, p: Vec2): bool =
  p.x >= r.x and p.x < r.x + r.width and
  p.y >= r.y and p.y < r.y + r.height

proc center*(r: Rect): Vec2 =
  vec2(r.x + r.width / 2, r.y + r.height / 2)

proc intersects*(a, b: Rect): bool =
  a.x < b.x + b.width and
  a.x + a.width > b.x and
  a.y < b.y + b.height and
  a.y + a.height > b.y

# Cursor Operations

proc `==`*(a, b: CursorPos): bool =
  a.line == b.line and a.col == b.col

proc `<`*(a, b: CursorPos): bool =
  a.line < b.line or (a.line == b.line and a.col < b.col)

proc `<=`*(a, b: CursorPos): bool =
  a < b or a == b

proc min*(a, b: CursorPos): CursorPos =
  if a < b: a else: b

proc max*(a, b: CursorPos): CursorPos =
  if a < b: b else: a

proc isValid*(pos: CursorPos, lineCount: int, lineLen: int): bool =
  pos.line >= 0 and pos.line < lineCount and
  pos.col >= 0 and pos.col <= lineLen

# Selection Operations

proc isEmpty*(sel: Selection): bool =
  sel.anchor == sel.caret

proc normalized*(sel: Selection): tuple[start, finish: CursorPos] =
  if sel.caret < sel.anchor:
    (sel.caret, sel.anchor)
  else:
    (sel.anchor, sel.caret)

proc contains*(sel: Selection, pos: CursorPos): bool =
  let (start, finish) = sel.normalized()
  pos >= start and pos <= finish

# Default Metadata

proc `$`*(le: LineEnding): string =
  case le
  of leLf: "LF"
  of leCrLf: "CRLF"
  of leCr: "CR"

proc defaultMetadata*(): DocumentMetadata =
  DocumentMetadata(
    language: "plaintext",
    encoding: "utf-8",
    tabSize: 4,
    useSpaces: true,
    lineEnding: leLf
  )

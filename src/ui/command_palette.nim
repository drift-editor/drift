## Command Palette Component for uirelays
## Immediate-mode centered overlay with search + filtered list

import std/[algorithm, sequtils, strutils, sugar]
import uirelays
import uirelays/[coords, screen, input]
import theme, icons

const
  PaletteWidth = 600
  PaletteHeight = 400
  SearchHeight = 44
  ItemHeight = 40
  MaxVisibleItems = 8

type
  CommandCategory* = enum
    ccFile
    ccEdit
    ccView
    ccSearch
    ccGit
    ccTools
    ccDebug
    ccHelp

  Command* = object
    id*: string
    name*: string
    description*: string
    category*: CommandCategory
    keybinding*: string
    action*: proc()
    preview*: proc()

  PaletteMode* = enum
    pmCommands
    pmFiles

  FileItem* = object
    name*: string
    path*: string

  CommandPalette* = ref object
    commands*: seq[Command]
    filteredCommands*: seq[Command]
    fileItems*: seq[FileItem]
    filteredFiles*: seq[FileItem]
    searchText*: string
    selectedIndex*: int
    hoverIndex*: int
    isVisible*: bool
    mode*: PaletteMode
    bounds*: Rect
    onClose*: proc()
    onFileSelect*: proc(path: string)
    beforeShow*: proc()

# Initialization

proc newCommandPalette*(): CommandPalette =
  CommandPalette(
    commands: @[],
    filteredCommands: @[],
    fileItems: @[],
    filteredFiles: @[],
    searchText: "",
    selectedIndex: 0,
    hoverIndex: -1,
    isVisible: false,
    mode: pmCommands,
    bounds: rect(0, 0, PaletteWidth, PaletteHeight)
  )

proc updateLayout*(palette: CommandPalette, viewport: Rect) =
  let x = (viewport.w - PaletteWidth) div 2 + viewport.x
  let y = (viewport.h - PaletteHeight) div 3 + viewport.y
  palette.bounds = rect(x, y, PaletteWidth, PaletteHeight)

# Command Management

proc registerCommand*(palette: CommandPalette, cmd: Command) =
  palette.commands.add(cmd)

proc registerCommand*(palette: CommandPalette,
                     id, name, description: string,
                     category: CommandCategory,
                     keybinding: string,
                     action: proc()) =
  palette.registerCommand(Command(
    id: id,
    name: name,
    description: description,
    category: category,
    keybinding: keybinding,
    action: action
  ))

proc registerCommand*(palette: CommandPalette,
                     id, name, description: string,
                     category: CommandCategory,
                     keybinding: string,
                     action, preview: proc()) =
  palette.registerCommand(Command(
    id: id,
    name: name,
    description: description,
    category: category,
    keybinding: keybinding,
    action: action,
    preview: preview
  ))

proc clearCommands*(palette: CommandPalette) =
  palette.commands = @[]
  palette.filteredCommands = @[]

proc noOp() {.sideEffect.} = discard

proc registerDefaults*(palette: CommandPalette) =
  palette.registerCommand("file.new", "New File", "Create a new file", ccFile, "Ctrl+N", noOp)
  palette.registerCommand("file.open", "Open File", "Open an existing file", ccFile, "Ctrl+O", noOp)
  palette.registerCommand("file.save", "Save", "Save current file", ccFile, "Ctrl+S", noOp)
  palette.registerCommand("file.saveAs", "Save As...", "Save with a new name", ccFile, "Ctrl+Shift+S", noOp)
  palette.registerCommand("edit.undo", "Undo", "Undo last action", ccEdit, "Ctrl+Z", noOp)
  palette.registerCommand("edit.redo", "Redo", "Redo last undone action", ccEdit, "Ctrl+Y", noOp)
  palette.registerCommand("edit.cut", "Cut", "Cut selection to clipboard", ccEdit, "Ctrl+X", noOp)
  palette.registerCommand("edit.copy", "Copy", "Copy selection to clipboard", ccEdit, "Ctrl+C", noOp)
  palette.registerCommand("edit.paste", "Paste", "Paste from clipboard", ccEdit, "Ctrl+V", noOp)
  palette.registerCommand("view.commandPalette", "Command Palette", "Show this command palette", ccView, "Ctrl+Shift+P", noOp)
  palette.registerCommand("view.toggleSidebar", "Toggle Sidebar", "Show/hide sidebar", ccView, "Ctrl+B", noOp)
  palette.registerCommand("view.toggleFullscreen", "Toggle Fullscreen", "Toggle fullscreen mode", ccView, "F11", noOp)
  palette.registerCommand("search.find", "Find", "Find in file", ccSearch, "Ctrl+F", noOp)
  palette.registerCommand("search.replace", "Replace", "Find and replace", ccSearch, "Ctrl+H", noOp)
  palette.registerCommand("search.gotoLine", "Go to Line", "Jump to specific line", ccSearch, "Ctrl+G", noOp)

# Mode switching

proc filterCommands*(palette: CommandPalette)
proc filterFiles*(palette: CommandPalette)

proc switchToCommandMode*(palette: CommandPalette) =
  palette.mode = pmCommands
  palette.searchText = ""
  palette.selectedIndex = 0
  palette.filterCommands()

proc switchToFileMode*(palette: CommandPalette, items: seq[FileItem]) =
  palette.mode = pmFiles
  palette.fileItems = items
  palette.searchText = ""
  palette.selectedIndex = 0
  palette.filterFiles()

# Filtering

proc calculateFuzzyScore(text, query: string): float =
  let textLower = text.toLowerAscii()
  let queryLower = query.toLowerAscii()

  if textLower == queryLower:
    return 1000.0
  if textLower.startsWith(queryLower):
    return 500.0 + 100.0 / textLower.len.float32

  # Consecutive character matching
  var score = 0.0
  var lastIdx = -1
  var consecutiveBonus = 0.0
  for qc in queryLower:
    let idx = textLower.find($qc, lastIdx + 1)
    if idx < 0:
      return 0.0
    if lastIdx >= 0 and idx == lastIdx + 1:
      consecutiveBonus += 15.0
    elif idx == 0 or textLower[idx - 1] in {'/', '_', '-', '.'}:
      consecutiveBonus += 10.0
    lastIdx = idx

  score = 100.0 + consecutiveBonus - (textLower.len - queryLower.len).float32 * 2.0
  # Penalize matches deep in the string
  score -= lastIdx.float32 * 1.5
  return max(1.0, score)

proc filterCommands*(palette: CommandPalette) =
  if palette.searchText.len == 0:
    palette.filteredCommands = palette.commands
  else:
    var scored: seq[tuple[cmd: Command, score: float]] = @[]
    for cmd in palette.commands:
      let nameScore = calculateFuzzyScore(cmd.name, palette.searchText)
      let descScore = calculateFuzzyScore(cmd.description, palette.searchText)
      let score = max(nameScore, descScore * 0.3)
      if score > 0:
        scored.add((cmd, score))
    scored.sort((a, b) => cmp(b.score, a.score))
    palette.filteredCommands = scored.mapIt(it.cmd)
  if palette.selectedIndex >= palette.filteredCommands.len:
    palette.selectedIndex = max(0, palette.filteredCommands.len - 1)

proc filterFiles*(palette: CommandPalette) =
  if palette.searchText.len == 0:
    palette.filteredFiles = palette.fileItems
  else:
    var scored: seq[tuple[item: FileItem, score: float]] = @[]
    for fi in palette.fileItems:
      let nameScore = calculateFuzzyScore(fi.name, palette.searchText)
      let pathScore = calculateFuzzyScore(fi.path, palette.searchText)
      # Filename matches are weighted higher
      let score = max(nameScore * 2.0, pathScore)
      if score > 0:
        scored.add((fi, score))
    scored.sort((a, b) => cmp(b.score, a.score))
    palette.filteredFiles = scored.mapIt(it.item)
  if palette.selectedIndex >= palette.filteredFiles.len:
    palette.selectedIndex = max(0, palette.filteredFiles.len - 1)

proc filterCurrent*(palette: CommandPalette) =
  case palette.mode
  of pmCommands: palette.filterCommands()
  of pmFiles: palette.filterFiles()

# Visibility Control

proc show*(palette: CommandPalette) =
  if palette.beforeShow != nil:
    palette.beforeShow()
  palette.isVisible = true
  palette.searchText = ""
  palette.selectedIndex = 0
  palette.hoverIndex = -1
  palette.filterCurrent()

proc hide*(palette: CommandPalette) =
  palette.isVisible = false
  palette.hoverIndex = -1
  if palette.onClose != nil:
    palette.onClose()

proc toggle*(palette: CommandPalette) =
  if palette.isVisible:
    palette.hide()
  else:
    palette.show()

# Input Handling

proc handleInput*(palette: CommandPalette, e: Event): bool =
  if not palette.isVisible:
    return false

  case e.kind
  of KeyDownEvent:
    case e.key
    of KeyEsc:
      palette.hide()
      return true
    of KeyEnter:
      case palette.mode
      of pmCommands:
        if palette.selectedIndex < palette.filteredCommands.len:
          let cmd = palette.filteredCommands[palette.selectedIndex]
          if cmd.action != nil:
            cmd.action()
          palette.hide()
      of pmFiles:
        if palette.selectedIndex < palette.filteredFiles.len:
          let fi = palette.filteredFiles[palette.selectedIndex]
          if palette.onFileSelect != nil:
            palette.onFileSelect(fi.path)
          palette.hide()
      return true
    of KeyUp:
      if palette.selectedIndex > 0:
        palette.selectedIndex -= 1
      return true
    of KeyDown:
      let maxIdx = case palette.mode
        of pmCommands: palette.filteredCommands.len - 1
        of pmFiles: palette.filteredFiles.len - 1
      if palette.selectedIndex < maxIdx:
        palette.selectedIndex += 1
      return true
    of KeyBackspace:
      if palette.searchText.len > 0:
        palette.searchText = palette.searchText[0..^2]
        palette.filterCurrent()
      return true
    else:
      return false
  of TextInputEvent:
    var s = ""
    for c in e.text:
      if c == '\0': break
      s.add(c)
    palette.searchText.add(s)
    palette.filterCurrent()
    return true
  of MouseDownEvent:
    let mousePos = point(e.x, e.y)
    if not palette.bounds.contains(mousePos):
      palette.hide()
      return true
    let listY = palette.bounds.y + SearchHeight + 16
    let listBounds = rect(palette.bounds.x + 8, listY, palette.bounds.w - 16, palette.bounds.h - SearchHeight - 24)
    if listBounds.contains(mousePos):
      let relativeY = mousePos.y - listY
      let index = relativeY div ItemHeight
      case palette.mode
      of pmCommands:
        if index >= 0 and index < palette.filteredCommands.len:
          palette.selectedIndex = index
          let cmd = palette.filteredCommands[index]
          if cmd.action != nil:
            cmd.action()
          palette.hide()
      of pmFiles:
        if index >= 0 and index < palette.filteredFiles.len:
          palette.selectedIndex = index
          let fi = palette.filteredFiles[index]
          if palette.onFileSelect != nil:
            palette.onFileSelect(fi.path)
          palette.hide()
    return true
  of MouseWheelEvent:
    let mousePos = point(e.x, e.y)
    if palette.bounds.contains(mousePos):
      let delta = e.y
      let maxIdx = case palette.mode
        of pmCommands: max(0, palette.filteredCommands.len - 1)
        of pmFiles: max(0, palette.filteredFiles.len - 1)
      if maxIdx >= 0:
        palette.selectedIndex = clamp(palette.selectedIndex - delta, 0, maxIdx)
    return true
  of MouseMoveEvent:
    let mousePos = point(e.x, e.y)
    if not palette.bounds.contains(mousePos):
      palette.hoverIndex = -1
      return false
    let listY = palette.bounds.y + SearchHeight + 16
    let listBounds = rect(palette.bounds.x + 8, listY, palette.bounds.w - 16, palette.bounds.h - SearchHeight - 24)
    if listBounds.contains(mousePos):
      let relativeY = mousePos.y - listY
      let index = relativeY div ItemHeight
      case palette.mode
      of pmCommands:
        if index >= 0 and index < palette.filteredCommands.len:
          palette.selectedIndex = index
          palette.hoverIndex = index
        else:
          palette.hoverIndex = -1
      of pmFiles:
        if index >= 0 and index < palette.filteredFiles.len:
          palette.selectedIndex = index
          palette.hoverIndex = index
        else:
          palette.hoverIndex = -1
    else:
      palette.hoverIndex = -1
    return true
  else:
    discard
  false

# Rendering

proc getCategoryIcon(category: CommandCategory): IconId =
  case category
  of ccFile: iiFile
  of ccEdit: iiEdit
  of ccView: iiListSelection
  of ccSearch: iiSearch
  of ccGit: iiGitBranch
  of ccTools: iiGear
  of ccDebug: iiGear
  of ccHelp: iiNone

proc render*(palette: CommandPalette, font: Font, viewport: Rect) =
  if not palette.isVisible:
    return
  palette.updateLayout(viewport)

  let bg = currentTheme.getColor(tcBackground)
  let surface = currentTheme.getColor(tcSurface)
  let border = currentTheme.getColor(tcBorder)
  let text = currentTheme.getColor(tcText)
  let textSecondary = currentTheme.getColor(tcTextSecondary)
  let accent = currentTheme.getColor(tcAccent)
  let selection = currentTheme.getColor(tcSelection)

  fillRect(rect(0, 0, viewport.w, viewport.h), color(0, 0, 0, 128))
  fillRect(palette.bounds, surface)
  fillRect(rect(palette.bounds.x, palette.bounds.y + palette.bounds.h - 1, palette.bounds.w, 1), border)

  let searchBounds = rect(palette.bounds.x + 8, palette.bounds.y + 8, palette.bounds.w - 16, SearchHeight)
  fillRect(searchBounds, bg)
  fillRect(rect(searchBounds.x, searchBounds.y + searchBounds.h - 1, searchBounds.w, 1), border)

  let searchDisplay = case palette.mode
    of pmCommands: (if palette.searchText.len > 0: palette.searchText else: "Type to search commands...")
    of pmFiles: (if palette.searchText.len > 0: palette.searchText else: "Type to search files...")
  let searchColor = if palette.searchText.len > 0: text else: textSecondary
  discard drawText(font, searchBounds.x + 12, searchBounds.y + 12, searchDisplay, searchColor, bg)

  if palette.searchText.len > 0:
    let cursorX = searchBounds.x + 12 + measureText(font, palette.searchText).w
    fillRect(rect(cursorX, searchBounds.y + 10, 2, SearchHeight - 20), text)

  let listY = palette.bounds.y + SearchHeight + 16

  case palette.mode
  of pmCommands:
    let maxItems = min(MaxVisibleItems, palette.filteredCommands.len)
    for i in 0..<maxItems:
      let cmd = palette.filteredCommands[i]
      let itemY = listY + i * ItemHeight
      let itemBounds = rect(palette.bounds.x + 8, itemY, palette.bounds.w - 16, ItemHeight)
      if i == palette.selectedIndex:
        fillRect(itemBounds, selection)
      drawIcon(getCategoryIcon(cmd.category), itemBounds.x + 8, itemBounds.y + 8)
      discard drawText(font, itemBounds.x + 28, itemBounds.y + 6, cmd.name, text, color(0, 0, 0, 0))
      discard drawText(font, itemBounds.x + 28, itemBounds.y + 24, cmd.description, textSecondary, color(0, 0, 0, 0))
      if cmd.keybinding.len > 0:
        discard drawText(font, itemBounds.x + itemBounds.w - 80, itemBounds.y + 12, cmd.keybinding, accent, color(0, 0, 0, 0))

    if palette.filteredCommands.len == 0:
      discard drawText(font, palette.bounds.x + 20, listY + 12, "No commands found", textSecondary, color(0, 0, 0, 0))

  of pmFiles:
    let maxItems = min(MaxVisibleItems, palette.filteredFiles.len)
    for i in 0..<maxItems:
      let fi = palette.filteredFiles[i]
      let itemY = listY + i * ItemHeight
      let itemBounds = rect(palette.bounds.x + 8, itemY, palette.bounds.w - 16, ItemHeight)
      if i == palette.selectedIndex:
        fillRect(itemBounds, selection)
      drawIcon(iiFile, itemBounds.x + 8, itemBounds.y + 8)
      discard drawText(font, itemBounds.x + 28, itemBounds.y + 6, fi.name, text, color(0, 0, 0, 0))
      discard drawText(font, itemBounds.x + 28, itemBounds.y + 24, fi.path, textSecondary, color(0, 0, 0, 0))

    if palette.filteredFiles.len == 0:
      discard drawText(font, palette.bounds.x + 20, listY + 12, "No files found", textSecondary, color(0, 0, 0, 0))

import std/os
import uirelays
import uirelays/screen
import theme, icons

const
  LEFT_MARGIN = 80
  TOP_MARGIN = 120
  COLUMN_WIDTH = 320
  SECTION_SPACING = 60
  ITEM_SPACING = 12
  ITEM_HEIGHT = 24

type
  WelcomeAction* = enum
    waNewFile
    waOpenFile
    waOpenFolder
    waCommands
    waDocumentation
    waRecentFile

  WelcomeItem* = object
    label*: string
    hotkey*: string
    icon*: IconId
    action*: WelcomeAction
    data*: string
    bounds*: Rect
    isHovered*: bool

  WelcomeSection* = object
    title*: string
    items*: seq[WelcomeItem]

  WelcomeScreen* = ref object
    isVisible*: bool
    title*: string
    subtitle*: string
    sections*: seq[WelcomeSection]
    recentFiles*: seq[tuple[path: string, isFolder: bool]]
    onNewFile*: proc()
    onOpenFile*: proc()
    onOpenFolder*: proc()
    onOpenRecent*: proc(path: string)
    onShowCommands*: proc()

proc newWelcomeScreen*(): WelcomeScreen =
  var screen = WelcomeScreen(
    isVisible: false,
    title: "Drift Editor",
    subtitle: "A fast, modern code editor",
    sections: @[],
    recentFiles: @[]
  )

  var startSection = WelcomeSection(title: "Start", items: @[])
  startSection.items.add(WelcomeItem(
    label: "New File", hotkey: "Ctrl+N", icon: iiNewFile, action: waNewFile
  ))
  startSection.items.add(WelcomeItem(
    label: "Open File", hotkey: "Ctrl+O", icon: iiFile, action: waOpenFile
  ))
  startSection.items.add(WelcomeItem(
    label: "Open Folder", hotkey: "Ctrl+Shift+O", icon: iiFolder, action: waOpenFolder
  ))
  screen.sections.add(startSection)

  screen.sections.add(WelcomeSection(title: "Recent", items: @[]))

  var helpSection = WelcomeSection(title: "Help", items: @[])
  helpSection.items.add(WelcomeItem(
    label: "Command Palette", hotkey: "Ctrl+Shift+P", icon: iiListSelection, action: waCommands
  ))
  helpSection.items.add(WelcomeItem(
    label: "Documentation", hotkey: "", icon: iiNone, action: waDocumentation
  ))
  screen.sections.add(helpSection)

  screen

proc truncateText(text: string, font: Font, maxWidth: int): string =
  if maxWidth <= 0:
    return ""
  let fullW = measureText(font, text).w
  if fullW <= maxWidth:
    return text
  var displayName = text
  while displayName.len > 3:
    let w = measureText(font, displayName & "...").w
    if w <= maxWidth:
      return displayName & "..."
    displayName.setLen(displayName.len - 1)
  "..."

proc updateRecentFiles*(screen: WelcomeScreen, files: seq[tuple[path: string, isFolder: bool]]) =
  screen.recentFiles = files
  for section in screen.sections.mitems:
    if section.title == "Recent":
      section.items = @[]
      for item in files:
        let icon = if item.isFolder: iiFolder else: iiHistory
        section.items.add(WelcomeItem(
          label: extractFilename(item.path), hotkey: "", icon: icon, action: waRecentFile, data: item.path
        ))
      break

proc triggerAction*(screen: WelcomeScreen, item: WelcomeItem) =
  case item.action
  of waNewFile:
    if screen.onNewFile != nil: screen.onNewFile()
  of waOpenFile:
    if screen.onOpenFile != nil: screen.onOpenFile()
  of waOpenFolder:
    if screen.onOpenFolder != nil: screen.onOpenFolder()
  of waRecentFile:
    if screen.onOpenRecent != nil: screen.onOpenRecent(item.data)
  of waCommands:
    if screen.onShowCommands != nil: screen.onShowCommands()
  of waDocumentation:
    discard

proc show*(screen: WelcomeScreen) =
  screen.isVisible = true

proc hide*(screen: WelcomeScreen) =
  screen.isVisible = false

proc toggle*(screen: WelcomeScreen) =
  screen.isVisible = not screen.isVisible

proc handleMouse*(screen: WelcomeScreen, e: Event, screenW, screenH: int): bool =
  if not screen.isVisible:
    return false

  if e.kind == MouseMoveEvent:
    var x = LEFT_MARGIN
    let baseY = TOP_MARGIN + 100
    var hovering = false
    for i in 0..<screen.sections.len:
      var y = baseY + 35
      for j in 0..<screen.sections[i].items.len:
        let itemBounds = rect(x, y, COLUMN_WIDTH, ITEM_HEIGHT)
        screen.sections[i].items[j].isHovered = itemBounds.contains(point(e.x, e.y))
        if screen.sections[i].items[j].isHovered:
          hovering = true
        y += ITEM_HEIGHT + ITEM_SPACING
      x += COLUMN_WIDTH + SECTION_SPACING
    return hovering

  if e.kind != MouseDownEvent:
    return false

  var x = LEFT_MARGIN
  let baseY = TOP_MARGIN + 100
  for i in 0..<screen.sections.len:
    var y = baseY + 35
    for j in 0..<screen.sections[i].items.len:
      let itemBounds = rect(x, y, COLUMN_WIDTH, ITEM_HEIGHT)
      screen.sections[i].items[j].bounds = itemBounds
      if itemBounds.contains(point(e.x, e.y)):
        screen.triggerAction(screen.sections[i].items[j])
        return true
      y += ITEM_HEIGHT + ITEM_SPACING
    x += COLUMN_WIDTH + SECTION_SPACING

  false

proc handleInput*(screen: WelcomeScreen, e: Event): bool =
  if not screen.isVisible:
    return false
  if e.kind != KeyDownEvent:
    return false
  let cmd = CtrlPressed in e.mods or GuiPressed in e.mods
  let shift = ShiftPressed in e.mods
  case e.key
  of KeyN:
    if cmd and not shift:
      if screen.onNewFile != nil: screen.onNewFile()
      return true
  of KeyO:
    if cmd and not shift:
      if screen.onOpenFile != nil: screen.onOpenFile()
      return true
    elif cmd and shift:
      if screen.onOpenFolder != nil: screen.onOpenFolder()
      return true
  of KeyP:
    if cmd and shift:
      if screen.onShowCommands != nil: screen.onShowCommands()
      return true
  of KeyEsc:
    screen.hide()
    return true
  else:
    discard
  false

proc render*(screen: WelcomeScreen, screenW, screenH: int, font: Font) =
  if not screen.isVisible:
    return

  # Background
  fillRect(rect(0, 0, screenW, screenH), currentTheme.getColor(tcBackground))

  # Title
  discard drawText(font, LEFT_MARGIN, TOP_MARGIN, screen.title,
                   currentTheme.getColor(tcText), color(0, 0, 0, 0))

  # Subtitle
  discard drawText(font, LEFT_MARGIN, TOP_MARGIN + 40, screen.subtitle,
                   currentTheme.getColor(tcTextSecondary), color(0, 0, 0, 0))

  # Sections
  var x = LEFT_MARGIN
  let y = TOP_MARGIN + 100

  for section in screen.sections:
    # Section title
    discard drawText(font, x, y, section.title,
                     currentTheme.getColor(tcText), color(0, 0, 0, 0))

    # Underline
    fillRect(rect(x, y + 22, COLUMN_WIDTH, 1), currentTheme.getColor(tcBorder))

    var itemY = y + 35
    for item in section.items:
      # Hover background with rounded feel
      if item.isHovered:
        fillRect(rect(x - 8, itemY - 4, COLUMN_WIDTH, 28), currentTheme.getColor(tcSelection))

      # Icon
      drawIcon(item.icon, x, itemY)

      # Label (truncated)
      let maxLabelW = COLUMN_WIDTH - 110
      let displayLabel = truncateText(item.label, font, maxLabelW)
      discard drawText(font, x + 25, itemY, displayLabel,
                       currentTheme.getColor(tcText), color(0, 0, 0, 0))

      # Hotkey
      if item.hotkey.len > 0:
        discard drawText(font, x + COLUMN_WIDTH - 100, itemY, item.hotkey,
                         currentTheme.getColor(tcTextSecondary), color(0, 0, 0, 0))

      itemY += ITEM_HEIGHT + ITEM_SPACING

    x += COLUMN_WIDTH + SECTION_SPACING

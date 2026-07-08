import std/[os, sets, sequtils]
import uirelays
import uirelays/screen
import theme, icons, context_menu

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
    pinnedPaths*: seq[string]
    onNewFile*: proc()
    onOpenFile*: proc()
    onOpenFolder*: proc()
    onOpenRecent*: proc(path: string)
    onShowCommands*: proc()
    onShowDocumentation*: proc()
    onShowTooltip*: proc(text: string; x, y: int)
    onHideTooltip*: proc()
    onPinToggle*: proc(path: string; pinned: bool)
    contextMenu*: ContextMenu
    font*: Font

proc newWelcomeScreen*(): WelcomeScreen =
  var screen = WelcomeScreen(
    isVisible: false,
    title: "Drift Editor",
    subtitle: "A fast, modern code editor",
    sections: @[],
    recentFiles: @[],
    pinnedPaths: @[],
    contextMenu: nil
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
    label: "Documentation", hotkey: "", icon: iiBook, action: waDocumentation
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

proc refreshRecentSection(screen: WelcomeScreen) =
  ## Rebuild the Recent section from screen.recentFiles and screen.pinnedPaths.
  ## Pinned items appear first (in the order they were pinned), followed by
  ## the remaining recent files in their original order.
  for section in screen.sections.mitems:
    if section.title != "Recent":
      continue
    section.items = @[]
    var usedPaths = initHashSet[string]()
    for pinnedPath in screen.pinnedPaths:
      for item in screen.recentFiles:
        if item.path == pinnedPath:
          let icon = if item.isFolder: iiFolder else: iiHistory
          let cleanPath = normalizePathEnd(item.path, trailingSep = false)
          let label = "\xF0\x9F\x93\x8C " & extractFilename(cleanPath)
          section.items.add(WelcomeItem(
            label: label, hotkey: "", icon: icon, action: waRecentFile, data: item.path
          ))
          usedPaths.incl(item.path)
          break
    for item in screen.recentFiles:
      if usedPaths.contains(item.path):
        continue
      let icon = if item.isFolder: iiFolder else: iiHistory
      let cleanPath = normalizePathEnd(item.path, trailingSep = false)
      section.items.add(WelcomeItem(
        label: extractFilename(cleanPath), hotkey: "", icon: icon, action: waRecentFile, data: item.path
      ))
    break

proc updateRecentFilesWithPins*(screen: WelcomeScreen;
                                files: seq[tuple[path: string, isFolder: bool]];
                                pinnedPaths: seq[string]) =
  screen.recentFiles = files
  screen.pinnedPaths = pinnedPaths
  refreshRecentSection(screen)

proc updateRecentFiles*(screen: WelcomeScreen, files: seq[tuple[path: string, isFolder: bool]]) =
  updateRecentFilesWithPins(screen, files, @[])

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
    if screen.onShowDocumentation != nil: screen.onShowDocumentation()

proc show*(screen: WelcomeScreen) =
  screen.isVisible = true

proc hide*(screen: WelcomeScreen) =
  screen.isVisible = false

proc toggle*(screen: WelcomeScreen) =
  screen.isVisible = not screen.isVisible

proc showPinMenu(screen: WelcomeScreen, path: string, x, y, screenW, screenH: int) =
  ## Show the right-click context menu for a recent file item.
  if screen.contextMenu == nil:
    screen.contextMenu = newContextMenu(screen.font)
  screen.contextMenu.clear()
  let isPinned = path in screen.pinnedPaths
  if isPinned:
    screen.contextMenu.addItem("unpin", "Unpin", proc() =
      screen.pinnedPaths.keepItIf(it != path)
      refreshRecentSection(screen)
      if screen.onPinToggle != nil:
        screen.onPinToggle(path, false)
    )
  else:
    screen.contextMenu.addItem("pin", "Pin", proc() =
      if path notin screen.pinnedPaths:
        screen.pinnedPaths.insert(path, 0)
      refreshRecentSection(screen)
      if screen.onPinToggle != nil:
        screen.onPinToggle(path, true)
    )
  screen.contextMenu.showAt(x, y, screenW, screenH)

proc handleMouse*(screen: WelcomeScreen, e: Event, screenW, screenH: int): bool =
  if not screen.isVisible:
    return false

  # Route input to an open context menu first.
  if screen.contextMenu != nil and screen.contextMenu.isVisible:
    if screen.contextMenu.handleInput(e):
      return true
    # Swallow mouse moves while a menu is open so tooltips don't flicker behind it.
    if e.kind == MouseMoveEvent:
      return true

  if e.kind == MouseMoveEvent:
    var x = LEFT_MARGIN
    let baseY = TOP_MARGIN + 100
    var hovering = false
    var hoveringRecent = false
    for i in 0..<screen.sections.len:
      var y = baseY + 35
      for j in 0..<screen.sections[i].items.len:
        let itemBounds = rect(x, y, COLUMN_WIDTH, ITEM_HEIGHT)
        screen.sections[i].items[j].isHovered = itemBounds.contains(point(e.x, e.y))
        if screen.sections[i].items[j].isHovered:
          hovering = true
          if screen.sections[i].title == "Recent" and
             screen.sections[i].items[j].action == waRecentFile:
            hoveringRecent = true
            if screen.onShowTooltip != nil:
              screen.onShowTooltip(screen.sections[i].items[j].data, e.x, e.y)
        y += ITEM_HEIGHT + ITEM_SPACING
      x += COLUMN_WIDTH + SECTION_SPACING
    if not hoveringRecent and screen.onHideTooltip != nil:
      screen.onHideTooltip()
    return hovering

  if e.kind != MouseDownEvent:
    return false

  # Right-click on a recent file opens the Pin/Unpin context menu.
  if e.button == RightButton:
    var x = LEFT_MARGIN
    let baseY = TOP_MARGIN + 100
    for i in 0..<screen.sections.len:
      var y = baseY + 35
      if screen.sections[i].title == "Recent":
        for j in 0..<screen.sections[i].items.len:
          let itemBounds = rect(x, y, COLUMN_WIDTH, ITEM_HEIGHT)
          if itemBounds.contains(point(e.x, e.y)) and
             screen.sections[i].items[j].action == waRecentFile:
            showPinMenu(screen, screen.sections[i].items[j].data, e.x, e.y, screenW, screenH)
            return true
          y += ITEM_HEIGHT + ITEM_SPACING
      x += COLUMN_WIDTH + SECTION_SPACING
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

  screen.font = font

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

  if screen.contextMenu != nil:
    screen.contextMenu.render()

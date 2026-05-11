import std/[os, algorithm, strutils, sets]
import uirelays
import uirelays/screen
import uirelays/input
import theme, icons

const
  ITEM_HEIGHT = 24
  INDENT_WIDTH = 16
  ICON_SIZE = 16
  PADDING = 8
  HEADER_HEIGHT = 30
  SCROLLBAR_WIDTH = 8

type
  FileNodeType* = enum
    fntFile
    fntDirectory

  FileNode* = ref object
    path*: string
    name*: string
    nodeType*: FileNodeType
    isExpanded: bool
    children: seq[FileNode]
    parent: FileNode
    isLoaded: bool

  FileExplorer* = ref object
    rootPath: string
    rootNode: FileNode
    selectedPath: string
    currentOpenPath: string
    isVisible: bool
    scrollOffset: int
    maxScroll: int
    expandedPaths: HashSet[string]
    onFileOpen*: proc(path: string)
    isFocused*: bool
    scrollbarDragging: bool
    scrollbarDragOffset: int
    visibleNodes: seq[FileNode]
    visibleNodesDirty: bool
    hoveredNode*: FileNode
    bounds*: Rect

proc newFileNode(path: string, parent: FileNode = nil): FileNode =
  let nodeType = if dirExists(path): fntDirectory else: fntFile
  FileNode(
    path: path,
    name: extractFilename(path),
    nodeType: nodeType,
    isExpanded: false,
    children: @[],
    parent: parent,
    isLoaded: false
  )

proc expand(node: FileNode, explorer: FileExplorer)  # Forward declaration

proc loadChildren(node: FileNode, explorer: FileExplorer) =
  if node.nodeType != fntDirectory or node.isLoaded:
    return
  node.children = @[]
  try:
    var dirs: seq[string] = @[]
    var files: seq[string] = @[]
    for kind, path in walkDir(node.path):
      let name = extractFilename(path)
      if name.startsWith("."):
        continue
      case kind
      of pcDir, pcLinkToDir:
        dirs.add(path)
      of pcFile, pcLinkToFile:
        files.add(path)
    dirs.sort()
    files.sort()
    for dirPath in dirs:
      let childNode = newFileNode(dirPath, node)
      node.children.add(childNode)
      # Restore expand state if this directory was previously expanded
      if childNode.path in explorer.expandedPaths:
        childNode.expand(explorer)
    for filePath in files:
      node.children.add(newFileNode(filePath, node))
    node.isLoaded = true
    # Note: caller should mark explorer.visibleNodesDirty = true after loadChildren if needed
  except CatchableError as e:
    stderr.writeLine("FileExplorer: failed to load children for ", node.path, ": ", e.msg)

proc expand(node: FileNode, explorer: FileExplorer) =
  if node.nodeType == fntDirectory:
    node.loadChildren(explorer)
    node.isExpanded = true

proc collapse(node: FileNode) =
  node.isExpanded = false

proc toggle(node: FileNode, explorer: FileExplorer) =
  if node.isExpanded:
    node.collapse()
  else:
    node.expand(explorer)

proc markDirty*(explorer: FileExplorer) =
  explorer.visibleNodesDirty = true

proc getIcon(node: FileNode): IconId =
  case node.nodeType
  of fntDirectory:
    if node.isExpanded: iiFolderOpened else: iiFolder
  of fntFile:
    let ext = splitFile(node.path).ext.toLowerAscii()
    case ext
    of ".nim": iiFileCode
    of ".py", ".js", ".ts", ".rs", ".go", ".c", ".cpp", ".h", ".hpp", ".java": iiFileCode
    of ".md", ".txt", ".rst": iiFile
    of ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg": iiGear
    of ".html", ".htm", ".css", ".scss", ".sass": iiFileCode
    of ".png", ".jpg", ".jpeg", ".gif", ".svg", ".bmp": iiFileMedia
    else: iiFile

proc countVisibleNodes(node: FileNode): int =
  result = 1
  if node.isExpanded:
    for child in node.children:
      result += countVisibleNodes(child)

proc getVisibleNodeAtIndex(node: FileNode, targetIdx: int, varIdx: var int): FileNode =
  if varIdx == targetIdx:
    return node
  varIdx += 1
  if node.isExpanded:
    for child in node.children:
      let found = getVisibleNodeAtIndex(child, targetIdx, varIdx)
      if found != nil:
        return found
  nil

proc getNodeIndex(node: FileNode, target: FileNode, varIdx: var int): int =
  if node == target:
    return varIdx
  result = -1
  varIdx += 1
  if node.isExpanded:
    for child in node.children:
      let idx = getNodeIndex(child, target, varIdx)
      if idx >= 0:
        return idx

proc findNodeByPath(node: FileNode, path: string): FileNode =
  if node.path == path:
    return node
  if node.isExpanded:
    for child in node.children:
      let found = findNodeByPath(child, path)
      if found != nil:
        return found
  nil

proc buildVisibleNodes(explorer: FileExplorer) =
  if not explorer.visibleNodesDirty:
    return
  explorer.visibleNodes.setLen(0)
  if explorer.rootNode == nil:
    explorer.visibleNodesDirty = false
    return
  proc walk(node: FileNode) =
    explorer.visibleNodes.add(node)
    if node.isExpanded:
      for child in node.children:
        walk(child)
  walk(explorer.rootNode)
  explorer.visibleNodesDirty = false

proc newFileExplorer*(): FileExplorer =
  FileExplorer(
    rootPath: "",
    rootNode: nil,
    selectedPath: "",
    currentOpenPath: "",
    isVisible: true,
    scrollOffset: 0,
    maxScroll: 0,
    expandedPaths: initHashSet[string](),
    onFileOpen: nil,
    isFocused: false,
    scrollbarDragging: false,
    scrollbarDragOffset: 0
  )

proc rootPath*(explorer: FileExplorer): string = explorer.rootPath

proc setRootPath*(explorer: FileExplorer, path: string) =
  explorer.rootPath = path
  explorer.rootNode = newFileNode(path)
  explorer.rootNode.expand(explorer)
  explorer.selectedPath = ""
  explorer.scrollOffset = 0
  explorer.visibleNodesDirty = true

proc refresh*(explorer: FileExplorer) =
  if explorer.rootNode != nil:
    explorer.rootNode.isLoaded = false
    explorer.rootNode.expand(explorer)
    explorer.visibleNodesDirty = true

proc collapseAll*(explorer: FileExplorer) =
  if explorer.rootNode != nil:
    for child in explorer.rootNode.children:
      child.collapse()
    explorer.expandedPaths.clear()
    explorer.visibleNodesDirty = true

proc nodeAt*(explorer: FileExplorer, x, y: int, bounds: Rect): FileNode =
  result = nil
  let relativeY = y - bounds.y - HEADER_HEIGHT - PADDING + explorer.scrollOffset
  if relativeY < 0:
    return nil
  buildVisibleNodes(explorer)
  let idx = relativeY div ITEM_HEIGHT
  if idx >= 0 and idx < explorer.visibleNodes.len:
    return explorer.visibleNodes[idx]

proc getSelectedNode*(explorer: FileExplorer): FileNode =
  if explorer.rootNode == nil or explorer.selectedPath.len == 0:
    return nil
  findNodeByPath(explorer.rootNode, explorer.selectedPath)

proc ensureSelectedVisible(explorer: FileExplorer, bounds: Rect) =
  let selected = explorer.getSelectedNode()
  if selected == nil or explorer.rootNode == nil:
    return
  buildVisibleNodes(explorer)
  var selectedIdx = -1
  for i, node in explorer.visibleNodes:
    if node == selected:
      selectedIdx = i
      break
  if selectedIdx < 0:
    return
  let contentH = bounds.h - HEADER_HEIGHT
  let visibleStart = explorer.scrollOffset div ITEM_HEIGHT
  let visibleCount = contentH div ITEM_HEIGHT
  if selectedIdx < visibleStart:
    explorer.scrollOffset = selectedIdx * ITEM_HEIGHT
  elif selectedIdx >= visibleStart + visibleCount:
    explorer.scrollOffset = (selectedIdx - visibleCount + 1) * ITEM_HEIGHT

# Input Handling

proc handleMouse*(explorer: FileExplorer, e: Event, bounds: Rect): bool =
  if not explorer.isVisible:
    return false

  if e.kind == MouseWheelEvent:
    let delta = e.y * ITEM_HEIGHT
    explorer.scrollOffset = max(0, min(explorer.maxScroll, explorer.scrollOffset - delta))
    return true

  if e.kind == MouseDownEvent:
    if not bounds.contains(point(e.x, e.y)):
      explorer.isFocused = false
      return false
    explorer.isFocused = true

    let relativeY = e.y - bounds.y - HEADER_HEIGHT - PADDING + explorer.scrollOffset
    if relativeY < 0:
      # Header area or scrollbar area
      let scrollbarX = bounds.x + bounds.w - SCROLLBAR_WIDTH
      if e.x >= scrollbarX and e.x < scrollbarX + SCROLLBAR_WIDTH and explorer.maxScroll > 0:
        let contentH = bounds.h - HEADER_HEIGHT
        let scrollbarTrackH = contentH
        let visibleRatio = contentH.float / (contentH + explorer.maxScroll).float
        let gripH = max(20, int(scrollbarTrackH.float * visibleRatio))
        let gripY = bounds.y + HEADER_HEIGHT + int(explorer.scrollOffset.float / explorer.maxScroll.float * (scrollbarTrackH - gripH).float)
        if e.y >= gripY and e.y < gripY + gripH:
          explorer.scrollbarDragging = true
          explorer.scrollbarDragOffset = e.y - gripY
        return true
      return false

    # Right click only sets focus — don't select/toggle (context menu handles that)
    if e.button == RightButton:
      buildVisibleNodes(explorer)
      let idx = relativeY div ITEM_HEIGHT
      if idx >= 0 and idx < explorer.visibleNodes.len:
        explorer.selectedPath = explorer.visibleNodes[idx].path
      return true

    buildVisibleNodes(explorer)
    let idx = relativeY div ITEM_HEIGHT
    if idx >= 0 and idx < explorer.visibleNodes.len:
      let node = explorer.visibleNodes[idx]
      var depth = 0
      var p = node.parent
      while p != nil:
        inc depth
        p = p.parent
      let iconX = bounds.x + PADDING + depth * INDENT_WIDTH
      if node.nodeType == fntDirectory and e.x >= iconX and e.x < iconX + ICON_SIZE:
        node.toggle(explorer)
        explorer.visibleNodesDirty = true
        if node.isExpanded:
          explorer.expandedPaths.incl(node.path)
        else:
          explorer.expandedPaths.excl(node.path)
      else:
        explorer.selectedPath = node.path
        if node.nodeType == fntDirectory:
          node.toggle(explorer)
          explorer.visibleNodesDirty = true
          if node.isExpanded:
            explorer.expandedPaths.incl(node.path)
          else:
            explorer.expandedPaths.excl(node.path)
        elif explorer.onFileOpen != nil:
          explorer.currentOpenPath = node.path
          explorer.onFileOpen(node.path)
    return true

  if e.kind == MouseUpEvent:
    explorer.scrollbarDragging = false

  if e.kind == MouseMoveEvent and explorer.scrollbarDragging:
    let contentH = bounds.h - HEADER_HEIGHT
    let scrollbarTrackH = contentH
    let visibleRatio = contentH.float / (contentH + explorer.maxScroll).float
    let gripH = max(20, int(scrollbarTrackH.float * visibleRatio))
    let trackY = bounds.y + HEADER_HEIGHT
    let newGripY = e.y - trackY - explorer.scrollbarDragOffset
    let maxGripY = scrollbarTrackH - gripH
    let scrollRatio = if maxGripY > 0: newGripY.float / maxGripY.float else: 0.0
    explorer.scrollOffset = max(0, min(explorer.maxScroll, int(scrollRatio * explorer.maxScroll.float)))
    return true

  if e.kind == MouseMoveEvent:
    if not bounds.contains(point(e.x, e.y)):
      explorer.hoveredNode = nil
      return false
    let relativeY = e.y - bounds.y - HEADER_HEIGHT - PADDING + explorer.scrollOffset
    if relativeY >= 0:
      buildVisibleNodes(explorer)
      let idx = relativeY div ITEM_HEIGHT
      if idx >= 0 and idx < explorer.visibleNodes.len:
        explorer.hoveredNode = explorer.visibleNodes[idx]
      else:
        explorer.hoveredNode = nil
    else:
      explorer.hoveredNode = nil
    return true

  false

proc handleInput*(explorer: FileExplorer, e: Event, bounds: Rect): bool =
  if not explorer.isVisible or not explorer.isFocused:
    return false
  if e.kind != KeyDownEvent:
    return false

  case e.key
  of KeyUp, KeyDown:
    if explorer.rootNode == nil:
      return false
    buildVisibleNodes(explorer)
    let visibleCount = explorer.visibleNodes.len
    if visibleCount == 0:
      return false
    var currentIdx = -1
    if explorer.selectedPath.len > 0:
      for i, node in explorer.visibleNodes:
        if node.path == explorer.selectedPath:
          currentIdx = i
          break

    if e.key == KeyUp:
      currentIdx = max(0, currentIdx - 1)
    else:
      currentIdx = min(visibleCount - 1, currentIdx + 1)

    if currentIdx >= 0 and currentIdx < visibleCount:
      explorer.selectedPath = explorer.visibleNodes[currentIdx].path
      ensureSelectedVisible(explorer, bounds)
    return true

  of KeyLeft:
    let selected = explorer.getSelectedNode()
    if selected != nil and selected.nodeType == fntDirectory:
      if selected.isExpanded:
        selected.collapse()
        explorer.visibleNodesDirty = true
        explorer.expandedPaths.excl(selected.path)
        return true
      elif selected.parent != nil and selected.parent != explorer.rootNode:
        explorer.selectedPath = selected.parent.path
        ensureSelectedVisible(explorer, bounds)
        return true
    return false

  of KeyRight:
    let selected = explorer.getSelectedNode()
    if selected != nil and selected.nodeType == fntDirectory:
      if not selected.isExpanded:
        selected.expand(explorer)
        explorer.visibleNodesDirty = true
        explorer.expandedPaths.incl(selected.path)
        return true
      elif selected.children.len > 0:
        buildVisibleNodes(explorer)
        var idx = -1
        for i, node in explorer.visibleNodes:
          if node == selected:
            idx = i
            break
        let firstChildIdx = idx + 1
        if firstChildIdx >= 0 and firstChildIdx < explorer.visibleNodes.len:
          explorer.selectedPath = explorer.visibleNodes[firstChildIdx].path
          ensureSelectedVisible(explorer, bounds)
        return true
    return false

  of KeyEnter:
    let selected = explorer.getSelectedNode()
    if selected != nil:
      if selected.nodeType == fntDirectory:
        selected.toggle(explorer)
        explorer.visibleNodesDirty = true
        if selected.isExpanded:
          explorer.expandedPaths.incl(selected.path)
        else:
          explorer.expandedPaths.excl(selected.path)
      elif explorer.onFileOpen != nil:
        explorer.currentOpenPath = selected.path
        explorer.onFileOpen(selected.path)
      return true
    return false

  else:
    discard
  false

# Rendering

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

proc renderNode(node: FileNode, explorer: FileExplorer, depth: int, varY: var int,
                bounds: Rect, font: Font, cont: seq[bool] = @[]) =
  let x = bounds.x + PADDING + depth * INDENT_WIDTH
  let y = bounds.y + varY - explorer.scrollOffset

  if y + ITEM_HEIGHT >= bounds.y and y < bounds.y + bounds.h:
    # Hover highlight
    if node == explorer.hoveredNode and node.path != explorer.selectedPath:
      fillRect(rect(bounds.x, y, bounds.w, ITEM_HEIGHT), currentTheme.getColor(tcSurfaceHover))

    # Selection highlight (full width)
    if node.path == explorer.selectedPath:
      fillRect(rect(bounds.x, y, bounds.w, ITEM_HEIGHT), currentTheme.getColor(tcSelection))

    # Current file indicator (subtle accent underline)
    if node.path == explorer.currentOpenPath and node.path != explorer.selectedPath:
      fillRect(rect(bounds.x, y + ITEM_HEIGHT - 2, bounds.w, 2), currentTheme.getColor(tcAccent))

    let lineColor = currentTheme.getColor(tcBorder)

    # Tree guide lines from ancestors
    for d in 0 ..< depth:
      let lineX = bounds.x + PADDING + d * INDENT_WIDTH + INDENT_WIDTH div 2
      let isParent = d == depth - 1
      if isParent:
        # Parent's vertical line always reaches midY so the horizontal connector can attach.
        let isLastChild = not cont[^1]
        let lineY2 = if isLastChild: y + ITEM_HEIGHT div 2 else: y + ITEM_HEIGHT
        drawLine(lineX, y, lineX, lineY2, lineColor)
      elif cont[d]:
        # Higher ancestors only when they have siblings after this branch.
        drawLine(lineX, y, lineX, y + ITEM_HEIGHT, lineColor)

    # Horizontal connector from parent to this node
    if depth > 0:
      let parentX = bounds.x + PADDING + (depth - 1) * INDENT_WIDTH + INDENT_WIDTH div 2
      let midY = y + ITEM_HEIGHT div 2
      drawLine(parentX, midY, x + 4, midY, lineColor)

    # Icon
    let iconX = x + 12
    drawIcon(node.getIcon(), iconX, y + 2)

    # Name
    let nameX = iconX + 20
    let maxNameWidth = bounds.w - (nameX - bounds.x) - PADDING - SCROLLBAR_WIDTH
    let displayName = truncateText(node.name, font, maxNameWidth)
    let nameColor = if node.path == explorer.currentOpenPath:
                      currentTheme.getColor(tcAccent)
                    else:
                      currentTheme.getColor(tcText)
    discard drawText(font, nameX, y + 4, displayName, nameColor, color(0, 0, 0, 0))

  varY += ITEM_HEIGHT
  if node.isExpanded:
    for i, child in node.children:
      var childCont = cont
      childCont.add(i != node.children.high)
      child.renderNode(explorer, depth + 1, varY, bounds, font, childCont)

proc render*(explorer: FileExplorer, bounds: Rect, font: Font) =
  explorer.bounds = bounds
  if not explorer.isVisible:
    return

  # Background
  fillRect(bounds, currentTheme.getColor(tcSurface))

  # Right edge border
  fillRect(rect(bounds.x + bounds.w - 1, bounds.y, 1, bounds.h), currentTheme.getColor(tcBorder))

  # Header (blends with panel surface, no separate background)
  let headerBounds = rect(bounds.x, bounds.y, bounds.w, HEADER_HEIGHT)
  fillRect(headerBounds, currentTheme.getColor(tcSurface))

  var headerPath = explorer.rootPath
  while headerPath.len > 0 and headerPath[^1] in {'/', '\\'}:
    headerPath.setLen(headerPath.len - 1)
  let headerText = if headerPath.len > 0: extractFilename(headerPath) else: "Explorer"
  discard drawText(font, bounds.x + PADDING, bounds.y + 6, headerText,
                   currentTheme.getColor(tcText), color(0, 0, 0, 0))

  # Content clip
  let contentBounds = rect(bounds.x, bounds.y + HEADER_HEIGHT, bounds.w, bounds.h - HEADER_HEIGHT)
  saveState()
  setClipRect(contentBounds)

  # Render tree
  if explorer.rootNode != nil:
    var y = HEADER_HEIGHT + PADDING
    explorer.rootNode.renderNode(explorer, 0, y, bounds, font)

    # Update max scroll
    let visibleH = bounds.h - HEADER_HEIGHT
    buildVisibleNodes(explorer)
    let totalH = explorer.visibleNodes.len * ITEM_HEIGHT + PADDING * 2
    explorer.maxScroll = max(0, totalH - visibleH)
    explorer.scrollOffset = min(explorer.scrollOffset, explorer.maxScroll)

    # Scrollbar
    if explorer.maxScroll > 0:
      let scrollbarX = bounds.x + bounds.w - SCROLLBAR_WIDTH
      let trackY = bounds.y + HEADER_HEIGHT
      # Grip
      let visibleRatio = visibleH.float / totalH.float
      let gripH = max(20, int(visibleH.float * visibleRatio))
      let gripY = trackY + int(explorer.scrollOffset.float / explorer.maxScroll.float * (visibleH - gripH).float)
      let gripColor = if explorer.scrollbarDragging:
                        currentTheme.getColor(tcAccentHover)
                      else:
                        currentTheme.getColor(tcTextSecondary)
      fillRect(rect(scrollbarX + 2, gripY, SCROLLBAR_WIDTH - 4, gripH), gripColor)

  restoreState()

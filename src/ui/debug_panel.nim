## Debug panel — displays DAP debugging state, call stack, variables, and output.

import std/[os, strutils]
import uirelays
import uirelays/screen
import uirelays/input
import theme
import ../core/debug_types

const
  DbgSectionHeight* = 26
  DbgRowHeight* = 22
  DbgOutputHeight* = 120
  DbgStackMaxHeight* = 120
  DbgIndentWidth* = 16

type
  DebugTreeNode* = ref object
    name*: string
    value*: string
    typeName*: string
    variablesReference*: int
    children*: seq[DebugTreeNode]
    expanded*: bool
    loading*: bool

  DebugPanel* = ref object
    state*: DebugSessionState
    frames*: seq[StackFrame]
    varNodes*: seq[DebugTreeNode]
    output*: seq[string]
    stackScrollOffset*: int
    varScrollOffset*: int
    hoverStackRow*: int
    hoverVarRow*: int
    onNavigate*: proc(path: string; line, col: int)
    onVariablesRequest*: proc(variablesReference: int)

# Panel lifecycle

proc newDebugPanel*(): DebugPanel =
  DebugPanel(
    state: dssOff,
    frames: @[],
    varNodes: @[],
    output: @[],
    stackScrollOffset: 0,
    varScrollOffset: 0,
    hoverStackRow: -1,
    hoverVarRow: -1,
    onNavigate: nil,
    onVariablesRequest: nil
  )

proc clear*(panel: DebugPanel) =
  panel.state = dssOff
  panel.frames = @[]
  panel.varNodes = @[]
  panel.output = @[]
  panel.stackScrollOffset = 0
  panel.varScrollOffset = 0
  panel.hoverStackRow = -1
  panel.hoverVarRow = -1

proc addOutput*(panel: DebugPanel; text: string) =
  for line in text.splitLines():
    panel.output.add(line)
  if panel.output.len > 500:
    panel.output = panel.output[^500..^1]

proc clearVariables*(panel: DebugPanel) =
  panel.varNodes = @[]
  panel.varScrollOffset = 0
  panel.hoverVarRow = -1

proc addScopes*(panel: DebugPanel; scopes: seq[Scope]) =
  for s in scopes:
    panel.varNodes.add(DebugTreeNode(
      name: s.name,
      value: "",
      typeName: "",
      variablesReference: s.variablesReference,
      children: @[],
      expanded: false,
      loading: false
    ))

proc findNodeByRef*(panel: DebugPanel; variablesReference: int): DebugTreeNode =
  var stack = panel.varNodes
  while stack.len > 0:
    let node = stack.pop()
    if node.variablesReference == variablesReference:
      return node
    for child in node.children:
      stack.add(child)
  nil

proc addVariables*(panel: DebugPanel; variablesReference: int; variables: seq[DebugVariable]) =
  let parent = panel.findNodeByRef(variablesReference)
  if parent == nil:
    return
  parent.children = @[]
  for v in variables:
    parent.children.add(DebugTreeNode(
      name: v.name,
      value: v.value,
      typeName: v.typeName,
      variablesReference: v.variablesReference,
      children: @[],
      expanded: false,
      loading: false
    ))
  parent.loading = false

# Tree flattening for rendering

type
  FlatVarRow = tuple[node: DebugTreeNode; depth: int]

proc flattenVariables(panel: DebugPanel): seq[FlatVarRow] =
  result = @[]
  var stack: seq[tuple[node: DebugTreeNode; depth: int]] = @[]
  # Add roots in reverse so they render left-to-right when popped
  for i in countdown(panel.varNodes.len - 1, 0):
    stack.add((panel.varNodes[i], 0))
  while stack.len > 0:
    let (node, depth) = stack.pop()
    result.add((node, depth))
    if node.expanded:
      # Add children in reverse so they render in order
      for i in countdown(node.children.len - 1, 0):
        stack.add((node.children[i], depth + 1))

proc canExpand(node: DebugTreeNode): bool =
  node.variablesReference > 0

proc displayLabel(node: DebugTreeNode): string =
  if node.value.len > 0:
    result = node.name & ": " & node.value
  else:
    result = node.name
  if node.typeName.len > 0:
    result.add("  (" & node.typeName & ")")

# Render

proc render*(panel: DebugPanel; bounds: Rect; font: Font; uiFont: Font) =
  let bg        = currentTheme.getColor(tcSurface)
  let bgHover   = currentTheme.getColor(tcSurfaceHover)
  let borderC   = currentTheme.getColor(tcBorder)
  let textC     = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let successC  = currentTheme.getColor(tcSuccess)
  let errorC    = currentTheme.getColor(tcError)

  fillRect(bounds, bg)
  fillRect(rect(bounds.x + bounds.w - 1, bounds.y, 1, bounds.h), borderC)

  var y = bounds.y + 4

  # Status line
  let statusLabel = "Status: "
  discard drawText(font, bounds.x + 8, y, statusLabel, textMuted, color(0, 0, 0, 0))
  let statusX = bounds.x + 8 + measureText(font, statusLabel).w + 4
  let statusColor = case panel.state
    of dssRunning: successC
    of dssStopped, dssError, dssTerminated: errorC
    else: textMuted
  discard drawText(font, statusX, y, panel.state.statusString(), statusColor, color(0, 0, 0, 0))
  y += DbgSectionHeight

  # Divider
  fillRect(rect(bounds.x + 4, y, bounds.w - 8, 1), borderC)
  y += 4

  # Call stack section header
  discard drawText(font, bounds.x + 8, y, "CALL STACK", textMuted, color(0, 0, 0, 0))
  y += DbgSectionHeight

  let stackHeaderY = y
  let stackContentH = panel.frames.len * DbgRowHeight
  let stackAreaH = min(stackContentH, DbgStackMaxHeight)

  saveState()
  setClipRect(rect(bounds.x, y, bounds.w, stackAreaH))

  panel.stackScrollOffset = min(panel.stackScrollOffset, max(0, stackContentH - stackAreaH))

  var rowY = y - panel.stackScrollOffset
  for i, frame in panel.frames:
    let rowBounds = rect(bounds.x, rowY, bounds.w, DbgRowHeight)
    if i == panel.hoverStackRow and rowBounds.y >= stackHeaderY and rowBounds.y + rowBounds.h <= stackHeaderY + stackAreaH:
      fillRect(rowBounds, bgHover)

    let frameText = if frame.source.len > 0:
      frame.name & "  —  " & extractFilename(frame.source) & ":" & $(frame.line + 1)
    else:
      frame.name
    let maxW = bounds.w - 24
    var displayText = frameText
    while displayText.len > 3 and measureText(font, displayText).w > maxW:
      displayText.setLen(displayText.len - 1)
    if displayText != frameText:
      displayText.add("...")

    discard drawText(font, bounds.x + 12, rowY + 3, displayText, textC, color(0, 0, 0, 0))
    rowY += DbgRowHeight

  restoreState()

  y += stackAreaH + 4

  # Variables section header
  fillRect(rect(bounds.x + 4, y - 2, bounds.w - 8, 1), borderC)
  discard drawText(font, bounds.x + 8, y, "VARIABLES", textMuted, color(0, 0, 0, 0))
  y += DbgSectionHeight

  let varHeaderY = y
  let outputY = bounds.y + bounds.h - DbgOutputHeight
  let varAreaH = max(0, outputY - 4 - y)

  saveState()
  setClipRect(rect(bounds.x, y, bounds.w, varAreaH))

  let flatVars = panel.flattenVariables()
  let varContentH = flatVars.len * DbgRowHeight
  panel.varScrollOffset = min(panel.varScrollOffset, max(0, varContentH - varAreaH))

  rowY = y - panel.varScrollOffset
  for i, (node, depth) in flatVars:
    let rowBounds = rect(bounds.x, rowY, bounds.w, DbgRowHeight)
    if i == panel.hoverVarRow and rowBounds.y >= varHeaderY and rowBounds.y + rowBounds.h <= varHeaderY + varAreaH:
      fillRect(rowBounds, bgHover)

    let indentX = bounds.x + 12 + depth * DbgIndentWidth
    let prefix = if node.canExpand:
      (if node.expanded: "- " else: "+ ")
    else:
      "  "
    let label = displayLabel(node)
    let maxW = bounds.w - (indentX - bounds.x) - 12
    var displayText = prefix & label
    while displayText.len > 3 and measureText(font, displayText).w > maxW:
      displayText.setLen(displayText.len - 1)
    if displayText != (prefix & label):
      displayText.add("...")

    let textColor = if node.canExpand: textC else: textMuted
    discard drawText(font, indentX, rowY + 3, displayText, textColor, color(0, 0, 0, 0))
    rowY += DbgRowHeight

  restoreState()

  # Output section
  fillRect(rect(bounds.x + 4, outputY - 4, bounds.w - 8, 1), borderC)
  discard drawText(font, bounds.x + 8, outputY, "DEBUG CONSOLE", textMuted, color(0, 0, 0, 0))

  saveState()
  setClipRect(rect(bounds.x, outputY + DbgSectionHeight, bounds.w, DbgOutputHeight - DbgSectionHeight))

  var outY = outputY + DbgSectionHeight
  let lineSkip = fontLineSkip(font)
  let visibleLines = (DbgOutputHeight - DbgSectionHeight) div max(1, lineSkip)
  let startIdx = max(0, panel.output.len - visibleLines)
  for i in startIdx ..< panel.output.len:
    discard drawText(font, bounds.x + 12, outY, panel.output[i], textC, color(0, 0, 0, 0))
    outY += lineSkip

  restoreState()

# Mouse handling

proc handleMouse*(panel: DebugPanel; e: Event; bounds: Rect): bool =
  if not bounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent:
      panel.hoverStackRow = -1
      panel.hoverVarRow = -1
    return false

  let statusEndY = bounds.y + 4 + DbgSectionHeight + 4
  let stackHeaderY = statusEndY
  let stackContentH = panel.frames.len * DbgRowHeight
  let stackAreaH = min(stackContentH, DbgStackMaxHeight)
  let varHeaderY = stackHeaderY + stackAreaH + 4 + DbgSectionHeight
  let outputY = bounds.y + bounds.h - DbgOutputHeight
  let varAreaH = max(0, outputY - 4 - varHeaderY)

  if e.kind == MouseWheelEvent:
    # Wheel over stack area
    if e.y >= stackHeaderY and e.y < varHeaderY - DbgSectionHeight - 4:
      let maxScroll = max(0, stackContentH - stackAreaH)
      panel.stackScrollOffset = clamp(panel.stackScrollOffset - e.y * DbgRowHeight, 0, maxScroll)
      return true
    # Wheel over variables area
    if e.y >= varHeaderY and e.y < outputY - 4:
      let flatVars = panel.flattenVariables()
      let varContentH = flatVars.len * DbgRowHeight
      let maxScroll = max(0, varContentH - varAreaH)
      panel.varScrollOffset = clamp(panel.varScrollOffset - e.y * DbgRowHeight, 0, maxScroll)
      return true
    return true

  # Stack area
  if e.y >= stackHeaderY and e.y < stackHeaderY + stackAreaH:
    let relY = e.y - stackHeaderY + panel.stackScrollOffset
    let rowIdx = relY div DbgRowHeight
    case e.kind
    of MouseMoveEvent:
      if rowIdx >= 0 and rowIdx < panel.frames.len:
        panel.hoverStackRow = rowIdx
      else:
        panel.hoverStackRow = -1
      panel.hoverVarRow = -1
      return true
    of MouseDownEvent:
      if rowIdx >= 0 and rowIdx < panel.frames.len:
        let frame = panel.frames[rowIdx]
        if panel.onNavigate != nil and frame.source.len > 0:
          panel.onNavigate(frame.source, frame.line, frame.column)
      return true
    else:
      discard

  # Variables area
  if e.y >= varHeaderY and e.y < outputY - 4:
    let flatVars = panel.flattenVariables()
    let relY = e.y - varHeaderY + panel.varScrollOffset
    let rowIdx = relY div DbgRowHeight
    case e.kind
    of MouseMoveEvent:
      if rowIdx >= 0 and rowIdx < flatVars.len:
        panel.hoverVarRow = rowIdx
      else:
        panel.hoverVarRow = -1
      panel.hoverStackRow = -1
      return true
    of MouseDownEvent:
      if rowIdx >= 0 and rowIdx < flatVars.len:
        let (node, _) = flatVars[rowIdx]
        if node.canExpand:
          if node.expanded:
            node.expanded = false
          else:
            node.expanded = true
            if node.children.len == 0 and not node.loading and panel.onVariablesRequest != nil:
              node.loading = true
              panel.onVariablesRequest(node.variablesReference)
      return true
    else:
      discard

  if e.kind == MouseMoveEvent:
    panel.hoverStackRow = -1
    panel.hoverVarRow = -1

  true

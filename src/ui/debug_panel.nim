## Debug panel — displays DAP debugging state, call stack, and output.

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

type
  DebugPanel* = ref object
    state*: DebugSessionState
    frames*: seq[StackFrame]
    output*: seq[string]
    scrollOffset*: int
    hoverRow*: int
    onNavigate*: proc(path: string; line, col: int)

# Panel lifecycle

proc newDebugPanel*(): DebugPanel =
  DebugPanel(
    state: dssOff,
    frames: @[],
    output: @[],
    scrollOffset: 0,
    hoverRow: -1,
    onNavigate: nil
  )

proc clear*(panel: DebugPanel) =
  panel.state = dssOff
  panel.frames = @[]
  panel.output = @[]
  panel.scrollOffset = 0

proc addOutput*(panel: DebugPanel; text: string) =
  for line in text.splitLines():
    panel.output.add(line)
  if panel.output.len > 500:
    panel.output = panel.output[^500..^1]

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

  saveState()
  setClipRect(rect(bounds.x, y, bounds.w, bounds.h - (y - bounds.y) - DbgOutputHeight - 8))

  var contentH = 0
  for i, frame in panel.frames:
    contentH += DbgRowHeight

  panel.scrollOffset = min(panel.scrollOffset, max(0, contentH - (bounds.h - (y - bounds.y) - DbgOutputHeight - 8)))

  var rowY = y - panel.scrollOffset
  for i, frame in panel.frames:
    let rowBounds = rect(bounds.x, rowY, bounds.w, DbgRowHeight)
    if i == panel.hoverRow and rowBounds.y >= y and rowBounds.y + rowBounds.h <= bounds.h - DbgOutputHeight - 8:
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

  # Output section
  let outputY = bounds.y + bounds.h - DbgOutputHeight
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
  if e.kind == MouseWheelEvent:
    var contentH = panel.frames.len * DbgRowHeight
    let stackAreaH = max(0, bounds.h - DbgOutputHeight - DbgSectionHeight - 8)
    let maxScroll = max(0, contentH - stackAreaH)
    panel.scrollOffset = clamp(panel.scrollOffset - e.y * DbgRowHeight, 0, maxScroll)
    return true

  if not bounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent: panel.hoverRow = -1
    return false

  # Call stack area bounds
  let stackHeaderY = bounds.y + 4 + DbgSectionHeight + 4 + DbgSectionHeight
  let outputY = bounds.y + bounds.h - DbgOutputHeight

  let relY = e.y - stackHeaderY + panel.scrollOffset
  if relY < 0 or e.y < stackHeaderY or e.y >= outputY:
    if e.kind == MouseMoveEvent: panel.hoverRow = -1
    return false

  let rowIdx = relY div DbgRowHeight
  case e.kind
  of MouseMoveEvent:
    if rowIdx >= 0 and rowIdx < panel.frames.len:
      panel.hoverRow = rowIdx
    else:
      panel.hoverRow = -1
    return true
  of MouseDownEvent:
    if rowIdx >= 0 and rowIdx < panel.frames.len:
      let frame = panel.frames[rowIdx]
      if panel.onNavigate != nil and frame.source.len > 0:
        panel.onNavigate(frame.source, frame.line, frame.column)
    return true
  else:
    discard

  false

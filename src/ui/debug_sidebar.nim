## Debug Sidebar — Run and Debug panel for the sidebar
## Similar to VSCode's Run and Debug activity view.

import std/os
import uirelays
import uirelays/screen
import uirelays/input
import theme, icons
import ../core/debug_types

const
  SectionHeaderHeight = 26
  RowHeight = 22
  ButtonHeight = 32

type
  DebugSidebar* = ref object
    state*: DebugSessionState
    frames*: seq[StackFrame]
    breakpoints*: seq[Breakpoint]
    hoverRow*: int
    hoverBtn*: string
    runBtnBounds*: Rect    ## Last rendered run button bounds (for hit-testing)
    stopBtnBounds*: Rect   ## Last rendered stop button bounds (for hit-testing)
    onStartDebug*: proc()
    onStopDebug*: proc()
    onStepOver*: proc()
    onStepInto*: proc()
    onStepOut*: proc()
    onContinue*: proc()
    onNavigate*: proc(path: string; line, col: int)
    onToggleBreakpoint*: proc(path: string; line: int)

proc newDebugSidebar*(): DebugSidebar =
  DebugSidebar(
    state: dssOff,
    frames: @[],
    breakpoints: @[],
    hoverRow: -1,
    hoverBtn: "",
  )

proc clear*(panel: DebugSidebar) =
  panel.state = dssOff
  panel.frames = @[]
  panel.hoverRow = -1

proc render*(panel: DebugSidebar; bounds: Rect; font: Font) =
  let bg        = currentTheme.getColor(tcSurface)
  let btnBg     = currentTheme.getColor(tcBackground)
  let bgHover   = currentTheme.getColor(tcSurfaceHover)
  let borderC   = currentTheme.getColor(tcBorder)
  let textC     = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let successC  = currentTheme.getColor(tcSuccess)
  let errorC    = currentTheme.getColor(tcError)

  fillRect(bounds, bg)
  fillRect(rect(bounds.x + bounds.w - 1, bounds.y, 1, bounds.h), borderC)

  var y = bounds.y + 4

  let isRunning = panel.state == dssRunning
  let isStopped = panel.state == dssStopped

  # Start / Continue button (status-bar-style: distinct bg + hover pill)
  let runLabel = if isRunning: "Continue" elif isStopped: "Continue" else: "Run and Debug"
  let runTextW = measureText(font, runLabel).w
  let runBtnW = 8 + 16 + 4 + runTextW + 12  # left pad + icon + gap + text + right pad
  let runBtnX = bounds.x + 8
  let runBtnBounds = rect(runBtnX, y, runBtnW, ButtonHeight)
  panel.runBtnBounds = runBtnBounds

  # Button with border for depth (like status bar top border)
  fillRect(runBtnBounds, btnBg)
  fillRect(rect(runBtnBounds.x, runBtnBounds.y, runBtnBounds.w, 1), borderC)
  fillRect(rect(runBtnBounds.x, runBtnBounds.y + runBtnBounds.h - 1, runBtnBounds.w, 1), borderC)
  fillRect(rect(runBtnBounds.x, runBtnBounds.y, 1, runBtnBounds.h), borderC)
  fillRect(rect(runBtnBounds.x + runBtnBounds.w - 1, runBtnBounds.y, 1, runBtnBounds.h), borderC)
  if panel.hoverBtn == "run":
    fillRect(runBtnBounds, bgHover)

  drawIcon(iiPlayGreen, runBtnX + 8, y + (ButtonHeight - 16) div 2)
  discard drawText(font, runBtnX + 28, y + (ButtonHeight - font.getFontMetrics().lineHeight) div 2 + 1,
                   runLabel, textC, color(0, 0, 0, 0))

  # Stop button (only when session is active)
  if panel.state.isActive:
    let stopBtnX = runBtnX + runBtnW + 8
    let stopBtnBounds = rect(stopBtnX, y, 32, ButtonHeight)
    panel.stopBtnBounds = stopBtnBounds

    fillRect(stopBtnBounds, btnBg)
    fillRect(rect(stopBtnBounds.x, stopBtnBounds.y, stopBtnBounds.w, 1), borderC)
    fillRect(rect(stopBtnBounds.x, stopBtnBounds.y + stopBtnBounds.h - 1, stopBtnBounds.w, 1), borderC)
    fillRect(rect(stopBtnBounds.x, stopBtnBounds.y, 1, stopBtnBounds.h), borderC)
    fillRect(rect(stopBtnBounds.x + stopBtnBounds.w - 1, stopBtnBounds.y, 1, stopBtnBounds.h), borderC)
    if panel.hoverBtn == "stop":
      fillRect(stopBtnBounds, bgHover)

    # Draw a small square as stop icon
    fillRect(rect(stopBtnX + 10, y + 10, 12, 12), errorC)
  else:
    panel.stopBtnBounds = rect(0, 0, 0, 0)

  y += ButtonHeight + 8

  let statusLabel = "Status: "
  discard drawText(font, bounds.x + 8, y, statusLabel, textMuted, color(0, 0, 0, 0))
  let statusX = bounds.x + 8 + measureText(font, statusLabel).w + 4
  let statusColor = case panel.state
    of dssRunning: successC
    of dssStopped, dssError, dssTerminated: errorC
    else: textMuted
  discard drawText(font, statusX, y, panel.state.statusString(), statusColor, color(0, 0, 0, 0))
  y += SectionHeaderHeight + 4

  fillRect(rect(bounds.x + 4, y, bounds.w - 8, 1), borderC)
  y += 8

  discard drawText(font, bounds.x + 8, y, "CALL STACK", textMuted, color(0, 0, 0, 0))
  y += SectionHeaderHeight

  for i, frame in panel.frames:
    let rowBounds = rect(bounds.x, y, bounds.w, RowHeight)
    if i == panel.hoverRow:
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

    discard drawText(font, bounds.x + 12, y + 3, displayText, textC, color(0, 0, 0, 0))
    y += RowHeight

  if panel.frames.len == 0:
    discard drawText(font, bounds.x + 12, y + 2, "No call stack", textMuted, color(0, 0, 0, 0))
    y += RowHeight

  y += 8

  fillRect(rect(bounds.x + 4, y, bounds.w - 8, 1), borderC)
  y += 8
  discard drawText(font, bounds.x + 8, y, "BREAKPOINTS", textMuted, color(0, 0, 0, 0))
  y += SectionHeaderHeight

  for bp in panel.breakpoints:
    let bpText = extractFilename(bp.path) & ":" & $(bp.line + 1)
    let bpColor = if bp.enabled: errorC else: textMuted
    fillRect(rect(bounds.x + 6, y + RowHeight div 2 - 3, 8, 8), bpColor)
    discard drawText(font, bounds.x + 20, y + 3, bpText, if bp.enabled: textC else: textMuted, color(0, 0, 0, 0))
    y += RowHeight

  if panel.breakpoints.len == 0:
    discard drawText(font, bounds.x + 12, y + 2, "No breakpoints", textMuted, color(0, 0, 0, 0))

proc handleMouse*(panel: DebugSidebar; e: Event; bounds: Rect): bool =
  if not bounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent:
      panel.hoverRow = -1
      panel.hoverBtn = ""
    return false

  var y = 4

  if panel.runBtnBounds.w > 0 and panel.runBtnBounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent:
      panel.hoverBtn = "run"
    elif e.kind == MouseDownEvent:
      if panel.state.canContinue:
        if panel.onContinue != nil: panel.onContinue()
      elif panel.state.canStart:
        if panel.onStartDebug != nil: panel.onStartDebug()
    return true

  if panel.stopBtnBounds.w > 0 and panel.stopBtnBounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent:
      panel.hoverBtn = "stop"
    elif e.kind == MouseDownEvent:
      if panel.onStopDebug != nil: panel.onStopDebug()
    return true

  y += ButtonHeight + 8

  y += SectionHeaderHeight + 4 + 8 + SectionHeaderHeight

  for i, frame in panel.frames:
    let rowBounds = rect(bounds.x, bounds.y + y, bounds.w, RowHeight)
    if e.kind == MouseMoveEvent:
      if rowBounds.contains(point(e.x, e.y)):
        panel.hoverRow = i
        panel.hoverBtn = ""
        return true
    elif e.kind == MouseDownEvent:
      if rowBounds.contains(point(e.x, e.y)):
        if panel.onNavigate != nil and frame.source.len > 0:
          panel.onNavigate(frame.source, frame.line, frame.column)
        return true
    y += RowHeight

  if e.kind == MouseMoveEvent:
    panel.hoverRow = -1
    panel.hoverBtn = ""

  true

proc handleInput*(panel: DebugSidebar; e: Event): bool =
  ## Keyboard input for the debug sidebar.
  if e.kind == KeyDownEvent:
    case e.key
    of KeyF5:
      if panel.state.canContinue:
        if panel.onContinue != nil: panel.onContinue()
      elif panel.state.canStart:
        if panel.onStartDebug != nil: panel.onStartDebug()
      return true
    else:
      discard
  false

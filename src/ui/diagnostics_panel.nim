## Diagnostics panel — displays LSP publishDiagnostics grouped by file.

import std/[tables, os, algorithm, sets]
import uirelays
import uirelays/screen
import uirelays/input
import theme, icons

# LSP severity levels
const
  SeverityError*   = 1
  SeverityWarning* = 2
  SeverityInfo*    = 3
  SeverityHint*    = 4

# Row heights
const
  DpGroupHeight* = 26
  DpEntryHeight* = 22

type
  DiagnosticEntry* = object
    uri*:      string
    severity*: int    ## LSP severity: 1=Error 2=Warning 3=Info 4=Hint
    message*:  string
    source*:   string
    line*:     int    ## 0-based
    col*:      int    ## 0-based

  DiagnosticStore* = object
    data*: Table[string, seq[DiagnosticEntry]]

  DiagnosticsPanel* = ref object
    store*:           DiagnosticStore
    scrollOffset*:    int
    collapsedGroups*: HashSet[string]
    hoverRow*:        int  ## flat row index into the rendered list; -1 = none
    onNavigate*:      proc(uri: string; line, col: int)

# Store

proc update*(store: var DiagnosticStore; uri: string; entries: seq[DiagnosticEntry]) =
  ## Replace entries for uri. Deletes the key when entries is empty.
  if entries.len == 0: store.data.del(uri)
  else: store.data[uri] = entries

proc errorCount*(store: DiagnosticStore): int =
  for entries in store.data.values:
    for e in entries:
      if e.severity == SeverityError: inc result

proc warningCount*(store: DiagnosticStore): int =
  for entries in store.data.values:
    for e in entries:
      if e.severity == SeverityWarning: inc result

# Panel lifecycle

proc newDiagnosticsPanel*(): DiagnosticsPanel =
  DiagnosticsPanel(
    store:           DiagnosticStore(),
    scrollOffset:    0,
    collapsedGroups: initHashSet[string](),
    hoverRow:        -1,
    onNavigate:      nil
  )

proc update*(panel: DiagnosticsPanel; uri: string; entries: seq[DiagnosticEntry]) =
  panel.store.update(uri, entries)

# Helpers

proc severityColor(severity: int): Color =
  case severity
  of SeverityError:   currentTheme.getColor(tcError)
  of SeverityWarning: currentTheme.getColor(tcWarning)
  of SeverityInfo:    currentTheme.getColor(tcInfo)
  else:               currentTheme.getColor(tcTextSecondary)

proc truncateText(text: string; font: Font; maxWidth: int): string =
  if maxWidth <= 0: return ""
  if measureText(font, text).w <= maxWidth: return text
  var s = text
  while s.len > 3:
    if measureText(font, s & "...").w <= maxWidth: return s & "..."
    s.setLen(s.len - 1)
  "..."

proc hasError(entries: seq[DiagnosticEntry]): bool =
  for e in entries:
    if e.severity == SeverityError: return true

proc sortedUris(store: DiagnosticStore): seq[string] =
  ## Files with at least one error sort before warning-only files, then alphabetically.
  for uri in store.data.keys: result.add(uri)
  result.sort(proc(a, b: string): int =
    let ae = hasError(store.data[a])
    let be = hasError(store.data[b])
    if ae != be: return (if ae: -1 else: 1)
    cmp(a, b))

proc sortedEntries(entries: seq[DiagnosticEntry]): seq[DiagnosticEntry] =
  result = entries
  result.sort(proc(a, b: DiagnosticEntry): int =
    if a.severity != b.severity: return cmp(a.severity, b.severity)
    cmp(a.line, b.line))

# Row list

type
  RowKind = enum rkGroup, rkEntry
  Row = object
    kind:  RowKind
    uri:   string
    entry: DiagnosticEntry  ## only valid for rkEntry

proc buildRows(panel: DiagnosticsPanel): seq[Row] =
  for uri in sortedUris(panel.store):
    result.add(Row(kind: rkGroup, uri: uri))
    if uri notin panel.collapsedGroups:
      for e in sortedEntries(panel.store.data[uri]):
        result.add(Row(kind: rkEntry, uri: uri, entry: e))

# Render

proc render*(panel: DiagnosticsPanel; bounds: Rect; font: Font; uiFont: Font) =
  let bg        = currentTheme.getColor(tcSurface)
  let bgHover   = currentTheme.getColor(tcSurfaceHover)
  let borderC   = currentTheme.getColor(tcBorder)
  let textC     = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)

  fillRect(bounds, bg)
  fillRect(rect(bounds.x + bounds.w - 1, bounds.y, 1, bounds.h), borderC)

  if panel.store.data.len == 0:
    let msg  = "No problems detected"
    let msgW = measureText(font, msg).w
    discard drawText(font,
      bounds.x + (bounds.w - msgW) div 2,
      bounds.y + bounds.h div 2 - 8,
      msg, textMuted, color(0, 0, 0, 0))
    return

  let rows = buildRows(panel)

  var contentH = 0
  for r in rows:
    contentH += (if r.kind == rkGroup: DpGroupHeight else: DpEntryHeight)
  panel.scrollOffset = min(panel.scrollOffset, max(0, contentH - bounds.h))

  saveState()
  setClipRect(bounds)

  var y    = bounds.y - panel.scrollOffset
  var rowI = 0

  for r in rows:
    let rowH      = if r.kind == rkGroup: DpGroupHeight else: DpEntryHeight
    let rowBounds = rect(bounds.x, y, bounds.w, rowH)

    if rowI == panel.hoverRow:
      fillRect(rowBounds, bgHover)

    if r.kind == rkGroup:
      let collapsed = r.uri in panel.collapsedGroups
      drawIcon(if collapsed: iiChevronRight else: iiChevronDown, bounds.x + 6, y + 5)

      let fileName = extractFilename(r.uri)
      let dirPart  = parentDir(r.uri)
      let nameX    = bounds.x + 26
      let nameW    = measureText(font, fileName).w
      discard drawText(font, nameX, y + 5, fileName, textC, color(0, 0, 0, 0))

      if dirPart.len > 0 and dirPart != ".":
        let pathX    = nameX + nameW + 6
        let maxPathW = bounds.w - (pathX - bounds.x) - 40
        discard drawText(font, pathX, y + 5,
          truncateText(dirPart, font, maxPathW), textMuted, color(0, 0, 0, 0))

      let cntText = "(" & $panel.store.data[r.uri].len & ")"
      discard drawText(font,
        bounds.x + bounds.w - measureText(font, cntText).w - 8,
        y + 5, cntText, textMuted, color(0, 0, 0, 0))

    else:
      let e      = r.entry
      let sevCol = severityColor(e.severity)
      let dotX   = bounds.x + 28
      let dotY   = y + (DpEntryHeight - 8) div 2
      fillRect(rect(dotX, dotY, 8, 8), sevCol)

      let msgX    = dotX + 14
      let locText = $(e.line + 1) & ":" & $(e.col + 1)
      let locW    = measureText(font, locText).w
      let srcW    = if e.source.len > 0: measureText(font, e.source).w + 6 else: 0
      let maxMsgW = bounds.w - (msgX - bounds.x) - locW - srcW - 16
      discard drawText(font, msgX, y + 3,
        truncateText(e.message, font, maxMsgW), textC, color(0, 0, 0, 0))

      if e.source.len > 0:
        discard drawText(font,
          bounds.x + bounds.w - locW - srcW - 8,
          y + 3, e.source, textMuted, color(0, 0, 0, 0))

      discard drawText(font,
        bounds.x + bounds.w - locW - 8,
        y + 3, locText, textMuted, color(0, 0, 0, 0))

    y    += rowH
    rowI += 1

  restoreState()

# Mouse handling

proc handleMouse*(panel: DiagnosticsPanel; e: Event; bounds: Rect): bool =
  ## Returns true when the event was consumed.
  if e.kind == MouseWheelEvent:
    let rows = buildRows(panel)
    var contentH = 0
    for r in rows: contentH += (if r.kind == rkGroup: DpGroupHeight else: DpEntryHeight)
    let maxScroll = max(0, contentH - bounds.h)
    panel.scrollOffset = clamp(panel.scrollOffset - e.y * DpEntryHeight, 0, maxScroll)
    return true

  if not bounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent: panel.hoverRow = -1
    return false

  let relY = e.y - bounds.y + panel.scrollOffset
  if relY < 0:
    if e.kind == MouseMoveEvent: panel.hoverRow = -1
    return false

  let rows = buildRows(panel)

  var rowI = 0
  var cumH = 0
  var hitRow = -1
  for r in rows:
    let rowH = if r.kind == rkGroup: DpGroupHeight else: DpEntryHeight
    if relY >= cumH and relY < cumH + rowH:
      hitRow = rowI
      break
    cumH  += rowH
    rowI  += 1

  case e.kind
  of MouseMoveEvent:
    panel.hoverRow = hitRow
    return true
  of MouseDownEvent:
    if hitRow < 0 or hitRow >= rows.len: return false
    let r = rows[hitRow]
    if r.kind == rkGroup:
      if r.uri in panel.collapsedGroups: panel.collapsedGroups.excl(r.uri)
      else: panel.collapsedGroups.incl(r.uri)
    else:
      if panel.onNavigate != nil:
        panel.onNavigate(r.entry.uri, r.entry.line, r.entry.col)
    return true
  else:
    discard

  false

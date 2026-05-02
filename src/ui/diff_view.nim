## Diff View — Side-by-side diff viewer with dual SynEdit panes

import std/os
import uirelays
import uirelays/screen
import uirelays/input
import widgets/synedit
import ../editor/diff_engine
import theme

proc diffDeleteBg(): Color =
  let c = currentTheme.getColor(tcError)
  color(c.r, c.g, c.b, 35)

proc diffInsertBg(): Color =
  let c = currentTheme.getColor(tcSuccess)
  color(c.r, c.g, c.b, 35)

proc diffReplaceBg(): Color =
  let c = currentTheme.getColor(tcWarning)
  color(c.r, c.g, c.b, 35)

proc applySyntaxFromPath(ed: var SynEdit; path: string) =
  let ext = path.splitFile.ext
  ed.lang = case ext
    of ".nim", ".nims": langNim
    of ".cpp", ".hpp", ".cxx", ".h": langCpp
    of ".c": langC
    of ".js": langJs
    of ".java": langJava
    of ".cs": langCsharp
    of ".xml": langXml
    of ".html", ".htm": langHtml
    of ".py", ".pyw": langPython
    of ".rs": langRust
    of ".md", ".markdown": langMarkdown
    else: langNone

type
  DiffView* = ref object
    leftEd*: SynEdit
    rightEd*: SynEdit
    oldPath*: string
    newPath*: string
    leftLabel*: string
    rightLabel*: string
    syncScroll*: bool
    bounds*: Rect
    hoverClose*: bool
    onClose*: proc()

proc newDiffView*(font: Font; theme: synedit.Theme): DiffView =
  var left = createSynEdit(font, theme)
  left.showLineNumbers = true
  left.readOnly = high(int)

  var right = createSynEdit(font, theme)
  right.showLineNumbers = true
  right.readOnly = high(int)

  DiffView(
    leftEd: left,
    rightEd: right,
    syncScroll: true,
    leftLabel: "Old",
    rightLabel: "New"
  )

proc applyDecorations*(dv: DiffView) =
  ## Re-apply diff decorations using current theme colors.
  dv.leftEd.clearLineBgDecorations()
  dv.rightEd.clearLineBgDecorations()

  let ops = diffText(dv.leftEd.fullText(), dv.rightEd.fullText())
  for op in ops:
    case op.kind
    of dokDelete:
      if op.oldLine >= 0:
        dv.leftEd.setLineBgDecoration(op.oldLine, diffDeleteBg())
    of dokInsert:
      if op.newLine >= 0:
        dv.rightEd.setLineBgDecoration(op.newLine, diffInsertBg())
    of dokReplace:
      if op.oldLine >= 0:
        dv.leftEd.setLineBgDecoration(op.oldLine, diffReplaceBg())
      if op.newLine >= 0:
        dv.rightEd.setLineBgDecoration(op.newLine, diffReplaceBg())
    of dokEqual:
      discard

proc setText*(dv: DiffView; oldText, newText: string) =
  ## Load both versions and compute diff decorations.
  dv.leftEd.setText(oldText)
  dv.rightEd.setText(newText)

  applySyntaxFromPath(dv.leftEd, dv.oldPath)
  applySyntaxFromPath(dv.rightEd, dv.newPath)

  dv.applyDecorations()

proc setLabels*(dv: DiffView; leftLabel, rightLabel: string) =
  dv.leftLabel = leftLabel
  dv.rightLabel = rightLabel

proc render*(dv: DiffView; bounds: Rect; font: Font; focused: bool) =
  dv.bounds = bounds

  let borderC = currentTheme.getColor(tcBorder)
  let textC = currentTheme.getColor(tcText)
  let headerBg = currentTheme.getColor(tcSurface)

  # Header bar
  let headerH = 28
  let headerBounds = rect(bounds.x, bounds.y, bounds.w, headerH)
  fillRect(headerBounds, headerBg)
  fillRect(rect(bounds.x, bounds.y + headerH - 1, bounds.w, 1), borderC)

  # Labels
  let midX = bounds.x + bounds.w div 2
  discard font.drawText(bounds.x + 8, bounds.y + 6, dv.leftLabel, textC, headerBg)
  discard font.drawText(midX + 8, bounds.y + 6, dv.rightLabel, textC, headerBg)

  # Close button
  let closeX = bounds.x + bounds.w - 24
  let closeBounds = rect(closeX, bounds.y + 4, 20, 20)
  if dv.hoverClose:
    fillRect(closeBounds, currentTheme.getColor(tcSurfaceHover))
  discard font.drawText(closeX + 5, bounds.y + 5, "×", textC, color(0, 0, 0, 0))

  # Divider line
  fillRect(rect(midX, bounds.y + headerH, 1, bounds.h - headerH), borderC)

  # Editor panes
  let paneY = bounds.y + headerH
  let paneH = bounds.h - headerH
  let paneW = bounds.w div 2
  let rightW = bounds.w - paneW - 1  # avoid 1px gap on odd widths

  let leftArea = rect(bounds.x, paneY, paneW, paneH)
  let rightArea = rect(midX + 1, paneY, rightW, paneH)

  var dummyEvent = Event(kind: NoEvent)
  discard dv.leftEd.draw(dummyEvent, leftArea, focused)
  discard dv.rightEd.draw(dummyEvent, rightArea, focused)

proc handleMouse*(dv: DiffView; e: Event): bool =
  if not dv.bounds.contains(point(e.x, e.y)):
    dv.hoverClose = false
    return false

  let headerH = 28
  let midX = dv.bounds.x + dv.bounds.w div 2
  let paneY = dv.bounds.y + headerH
  let paneH = dv.bounds.h - headerH
  let paneW = dv.bounds.w div 2

  # Close button hit-test
  let closeX = dv.bounds.x + dv.bounds.w - 24
  let closeBounds = rect(closeX, dv.bounds.y + 4, 20, 20)
  let inClose = closeBounds.contains(point(e.x, e.y))

  if e.kind == MouseMoveEvent:
    dv.hoverClose = inClose

  if e.kind == MouseDownEvent and inClose:
    if dv.onClose != nil:
      dv.onClose()
    return true

  let leftArea = rect(dv.bounds.x, paneY, paneW, paneH)
  let rightArea = rect(midX + 1, paneY, dv.bounds.w - paneW - 1, paneH)

  if e.kind == MouseDownEvent or e.kind == MouseMoveEvent or e.kind == MouseUpEvent:
    # Route to appropriate editor
    if e.x < midX:
      discard dv.leftEd.draw(e, leftArea, true)
    else:
      discard dv.rightEd.draw(e, rightArea, true)

    # Synchronize scroll if enabled
    if dv.syncScroll and e.kind == MouseMoveEvent:
      dv.rightEd.firstLine = dv.leftEd.firstLine
      dv.rightEd.firstLineOffset = dv.leftEd.firstLineOffset

    return true

  if e.kind == MouseWheelEvent:
    if e.x < midX:
      dv.leftEd.scrollLines(-e.y * 3)
      if dv.syncScroll:
        dv.rightEd.firstLine = dv.leftEd.firstLine
        dv.rightEd.firstLineOffset = dv.leftEd.firstLineOffset
    else:
      dv.rightEd.scrollLines(-e.y * 3)
      if dv.syncScroll:
        dv.leftEd.firstLine = dv.rightEd.firstLine
        dv.leftEd.firstLineOffset = dv.rightEd.firstLineOffset
    return true

  false

proc scrollTo*(dv: DiffView; line: int) =
  dv.leftEd.firstLine = max(0, line).Natural
  dv.leftEd.firstLineOffset = 0
  if dv.syncScroll:
    dv.rightEd.firstLine = dv.leftEd.firstLine
    dv.rightEd.firstLineOffset = 0

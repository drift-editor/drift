## Status-bar rendering, LSP/DAP status strings, clickable section bounds.

proc lspStatusString(app: App): string =
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    return "LSP: " & app.lspServer
  elif app.lspStarting:
    return "LSP: starting..."
  else:
    return "LSP: off"


proc lspStatusTooltip(app: App): string =
  ## Detailed tooltip shown when hovering the status-bar LSP section.
  let state = if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    "ready"
  elif app.lspStarting:
    "starting"
  elif app.lspThread != nil:
    "error"
  else:
    "off"
  result = "Server: " & app.lspServer & "\nLanguage: " & app.lspLanguage & "\nState: " & state
  if app.lspErrorMsg.len > 0:
    result.add("\nError: " & app.lspErrorMsg)


proc dapStatusString(app: App): string =
  case app.debugState
  of dssOff: "DBG: off"
  of dssStarting: "DBG: starting..."
  of dssReady: "DBG: ready"
  of dssRunning: "DBG: running"
  of dssStopped: "DBG: stopped"
  of dssError: "DBG: error"
  of dssTerminated: "DBG: terminated"


proc updateStatus(app: App) =
  var leftSections: seq[string]
  var rightSections: seq[string]
  var lspIdx = -1
  var dapIdx = -1
  var aiIdx = -1
  var currLine = 0
  var currCol = 0
  let branch = app.gitPanel.currentBranch
  let branchLabel = if branch.len > 0:
    branch & (if app.gitPanel.isDirty: " *" else: "")
  else: ""

  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    leftSections = if branchLabel.len > 0:
      @[branchLabel, "No file"]
    else:
      @["No file"]
    rightSections = @[app.lspStatusString(), app.dapStatusString(), "AI"]
    lspIdx = 0
    dapIdx = 1
    aiIdx = 2
  else:
    let b = app.buffers[app.currentBuffer]
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    if b.isImage:
      leftSections = @[name]
      rightSections = @[
        $b.imageWidth & " x " & $b.imageHeight,
        app.lspStatusString(),
        app.dapStatusString(),
        "AI"
      ]
      lspIdx = 1
      dapIdx = 2
      aiIdx = 3
    elif b.diffPath.len > 0:
      leftSections = @[name]
      rightSections = @["Diff", app.lspStatusString(), app.dapStatusString(), "AI"]
      lspIdx = 1
      dapIdx = 2
      aiIdx = 3
      app.statusBar.lineEndingIndex = -1
      app.statusBar.encodingIndex = -1
    else:
      let modified = if b.ed.changed: " *" else: ""
      let text = b.ed.fullText
      let lineEnding = detectLineEnding(text)
      let lang = langToString(b.ed.lang)
      currLine = b.ed.currentLine
      currCol = b.ed.currentCol
      leftSections = if branchLabel.len > 0:
        @[branchLabel, name & modified]
      else:
        @[name & modified]
      rightSections = @[
        "Ln " & $(currLine + 1) & ", Col " & $(currCol + 1),
        "UTF-8",
        $lineEnding,
        lang,
        app.lspStatusString(),
        app.dapStatusString(),
        "AI"
      ]
      lspIdx = 4
      dapIdx = 5
      aiIdx = 6
      app.statusBar.encodingIndex = 1
      app.statusBar.lineEndingIndex = 2

  let statusText = leftSections.join(" | ") & " :: " & rightSections.join(" | ")
  if statusText != app.lastStatusText or currLine != app.lastCurrentLine or currCol != app.lastCurrentCol:
    app.statusBar.leftSections = leftSections
    app.statusBar.rightSections = rightSections
    app.statusBar.leftIcons = if leftSections.len > 0 and app.gitPanel.currentBranch.len > 0:
      @[iiGitBranch] & newSeq[IconId](leftSections.len - 1)
    else:
      newSeq[IconId](leftSections.len)
    app.statusBar.rightIcons = newSeq[IconId](rightSections.len)
    app.statusBar.rightIcons[^1] = iiSparkle
    app.statusBar.rightColors = @[]
    for _ in 0 ..< rightSections.len:
      app.statusBar.rightColors.add(color(0, 0, 0, 0))
    app.statusBar.activeRightIndex = -1
    app.statusBar.lspIndex = lspIdx
    app.statusBar.dapIndex = dapIdx
    app.statusBar.aiIndex = aiIdx
    app.lastStatusText = statusText
    app.lastCurrentLine = currLine
    app.lastCurrentCol = currCol

  # Diagnostic summary section (always updated since counts change independently)
  let errCount = app.diagPanel.store.errorCount()
  let warnCount = app.diagPanel.store.warningCount()
  let baseLen = leftSections.len

  # Always show: [iiError] N  [iiWarning] N
  app.statusBar.leftSections.setLen(baseLen)
  app.statusBar.leftIcons.setLen(baseLen)
  app.statusBar.leftColors.setLen(baseLen)

  let errColor = if errCount > 0: currentTheme.getColor(tcError) else: currentTheme.getColor(tcText)
  let warnColor = if warnCount > 0: currentTheme.getColor(tcWarning) else: currentTheme.getColor(tcText)

  app.statusBar.leftSections.add($errCount)
  app.statusBar.leftIcons.add(iiError)
  app.statusBar.leftColors.add(errColor)

  app.statusBar.leftSections.add($warnCount)
  app.statusBar.leftIcons.add(iiWarning)
  app.statusBar.leftColors.add(warnColor)



proc rightSectionIndexAt(app: App, statusBounds: coords.Rect, px, py: int): int =
  ## Returns the index of the right status bar section at (px, py), or -1.
  if not statusBounds.contains(point(px, py)): return -1
  let font = app.statusFont
  var rightWidth = 0
  var sectionWidths: seq[int]
  for i, text in app.statusBar.rightSections:
    let ext = font.measureText(text)
    var sectionW = ext.w + SectionPadding * 2
    let icon = if i < app.statusBar.rightIcons.len: app.statusBar.rightIcons[i] else: iiNone
    if icon != iiNone:
      sectionW += 16 + 4
    sectionWidths.add(sectionW)
    rightWidth += sectionW
  var x = statusBounds.x + statusBounds.w - rightWidth + SectionPadding
  for i, w in sectionWidths:
    if px >= x and px < x + w:
      return i
    x += w
  return -1


proc sectionBoundsAtIndex(app: App, statusBounds: coords.Rect, idx: int): coords.Rect =
  ## Compute the bounds of the right status bar section at the given index.
  if idx < 0 or idx >= app.statusBar.rightSections.len:
    return rect(0, 0, 0, 0)
  let font = app.statusFont
  var rightWidth = 0
  for i, text in app.statusBar.rightSections:
    let ext = font.measureText(text)
    var sectionW = ext.w + SectionPadding * 2
    let icon = if i < app.statusBar.rightIcons.len: app.statusBar.rightIcons[i] else: iiNone
    if icon != iiNone:
      sectionW += 16 + 4
    rightWidth += sectionW
  var x = statusBounds.x + statusBounds.w - rightWidth + SectionPadding
  for i, text in app.statusBar.rightSections:
    let ext = font.measureText(text)
    var w = ext.w + SectionPadding * 2
    let icon = if i < app.statusBar.rightIcons.len: app.statusBar.rightIcons[i] else: iiNone
    if icon != iiNone:
      w += 16 + 4
    if i == idx:
      return rect(x, statusBounds.y, w, statusBounds.h)
    x += w


proc aiSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  sectionBoundsAtIndex(app, statusBounds, app.statusBar.aiIndex)


proc pushClipboardHistory*(app: App, text: string) =
  ## Add text to the clipboard ring, removing duplicates and capping at config size.
  if text.len == 0 or app.config.clipboardHistorySize <= 0:
    return
  let idx = app.clipboardHistory.find(text)
  if idx >= 0:
    app.clipboardHistory.delete(idx)
  app.clipboardHistory.insert(text, 0)
  if app.clipboardHistory.len > app.config.clipboardHistorySize:
    app.clipboardHistory.setLen(app.config.clipboardHistorySize)


proc lspSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  sectionBoundsAtIndex(app, statusBounds, app.statusBar.lspIndex)


proc branchSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  if app.statusBar.leftSections.len < 2: return rect(0, 0, 0, 0)
  let font = app.statusFont
  let ext = font.measureText(app.statusBar.leftSections[0])
  let iconW = 16 + 4  # icon + gap
  let w = iconW + ext.w + SectionPadding * 2
  return rect(statusBounds.x + SectionPadding, statusBounds.y, w, statusBounds.h)


proc diagSectionBounds(app: App, statusBounds: coords.Rect): coords.Rect =
  ## Returns the bounds covering both the error and warning status bar sections (last 2 left sections).
  if app.statusBar.leftSections.len < 2: return rect(0, 0, 0, 0)
  let font = app.statusFont
  var x = statusBounds.x + SectionPadding
  let diagStart = app.statusBar.leftSections.len - 2  # first of the two diag slots
  for i, text in app.statusBar.leftSections:
    let icon = if i < app.statusBar.leftIcons.len: app.statusBar.leftIcons[i] else: iiNone
    let iconW = if icon != iiNone: 16 + 4 else: 0
    let ext = font.measureText(text)
    let w = iconW + ext.w + SectionPadding * 2
    if i == diagStart:
      # measure from here to end of last section
      var totalW = w
      if i + 1 < app.statusBar.leftSections.len:
        let icon2 = if i+1 < app.statusBar.leftIcons.len: app.statusBar.leftIcons[i+1] else: iiNone
        let iconW2 = if icon2 != iiNone: 16 + 4 else: 0
        let ext2 = font.measureText(app.statusBar.leftSections[i+1])
        totalW += iconW2 + ext2.w + SectionPadding * 2
      return rect(x, statusBounds.y, totalW, statusBounds.h)
    x += w


proc updateTitle(app: App) =
  if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
    let b = app.buffers[app.currentBuffer]
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    let prefix = if b.ed.changed: "鈥?" else: ""
    setWindowTitle(prefix & name & " - Drift")
  else:
    setWindowTitle("Drift")


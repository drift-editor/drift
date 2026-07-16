## LSP wiring: applying edits, selection ranges, server restart, diagnostics.

proc applyLspEditsToBuffer(app: App, idx: int, edits: seq[LSPTextEdit]) =
  ## Apply a sequence of LSP text edits to an open buffer and notify the LSP server.
  if idx < 0 or idx >= app.buffers.len or edits.len == 0:
    return
  let b = addr app.buffers[idx]
  let newText = applyTextEdits(b.ed.fullText, edits)
  b.ed.setText(newText)
  b.ed.markChanged()
  b.lastChanged = true
  app.tabBar.updateTabModified($idx, true)
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    app.lspThread.notifyDidChange(b.path, newText)


proc lspRangeForSelection(ed: SynEdit): Option[LSPRange] =
  ## Derive an LSP range from the current editor selection.
  ## SynEdit does not expose selection offsets, so we locate the selected text
  ## in the full buffer and pick the occurrence closest to the cursor.
  let selected = ed.getSelectedText()
  if selected.len == 0:
    return none(LSPRange)
  let full = ed.fullText()
  let cursorOff = offsetAtLineCol(full, ed.currentLine, ed.currentCol)
  var bestStart = -1
  var bestDist = high(int)
  var start = 0
  while start <= full.len - selected.len:
    let idx = find(full, selected, start)
    if idx < 0:
      break
    let endOff = idx + selected.len
    let dist = if cursorOff >= idx and cursorOff <= endOff:
      0
    else:
      min(abs(cursorOff - idx), abs(cursorOff - endOff))
    if dist < bestDist:
      bestDist = dist
      bestStart = idx
      if dist == 0:
        break
    start = idx + 1
  if bestStart < 0:
    return none(LSPRange)
  let (startLine, startCol) = lineColAtOffset(full, bestStart)
  let (endLine, endCol) = lineColAtOffset(full, bestStart + selected.len)
  return some(LSPRange(
    start: LSPPosition(line: startLine, character: startCol),
    `end`: LSPPosition(line: endLine, character: endCol)
  ))


proc lspExeFor(serverName: string): string =
  case serverName
  of "languageserver": "nimlangserver"
  else: serverName


proc restartLSP(app: App, serverName: string) =
  let lang = if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
               languageIdFor(app.buffers[app.currentBuffer].path)
             else:
               "nim"
  app.lspLanguage = lang
  app.lspServer = serverName
  app.config.lspServers[lang] = serverName
  if lang == "nim":
    app.config.lspServer = serverName
  saveAppConfig(app)
  # Stop existing LSP
  if app.lspThread != nil:
    app.lspThread.shutdown()
    app.lspThread = nil
  app.lspStarting = false
  # Clear diagnostics 鈥?both editor decorations and the panel store
  for i in 0 ..< app.lastDiagLines.len:
    app.lastDiagLines[i] = @[]
    if i < app.bufferMarkers.len:
      app.bufferMarkers[i].setMarkers(msDiagnostic, @[])
      applyMarkers(app.buffers[i].ed, app.bufferMarkers[i])
  app.diagPanel.store = DiagnosticStore()
  # Restart if any buffer of this language is open
  var hasLang = false
  for b in app.buffers:
    if languageIdFor(b.path) == lang:
      hasLang = true
      break
  if hasLang:
    app.lspThread = newLSPThread(lspExeFor(app.lspServer), lang, app.config.lspConfig)
    app.lspStarting = true


proc showLSPServerMenu(app: App, lspBounds: coords.Rect) =
  app.lspMenu.items = @[]
  let servers = @[("minlsp", "minlsp"), ("languageserver", "nimlangserver"), ("nimlsp", "nimlsp")]
  proc makeRestartProc(server: string): proc() =
    result = proc() = restartLSP(app, server)
  for (lbl, exe) in servers:
    let available = findExe(exe).len > 0
    let isCurrent = app.lspServer == lbl
    let label = lbl
    var item: MenuItem
    if isCurrent and available:
      item = newCheckboxItem(label, label, true, makeRestartProc(label))
    elif available:
      item = newMenuItem(label, label, makeRestartProc(label))
    else:
      item = newMenuItem(label, label & " (not found)", proc() = discard)
      item.isEnabled = false
    app.lspMenu.addItem(item)
  app.lspMenu.showAt(lspBounds.x, lspBounds.y)
  app.lspMenu.bounds.x = lspBounds.x + lspBounds.w - app.lspMenu.bounds.w
  app.lspMenu.bounds.y -= app.lspMenu.bounds.h


proc handleDiagnostics(app: App; msg: JsonNode) =
  if not msg.hasKey("params"): return
  let params = msg["params"]
  if not params.hasKey("uri") or not params.hasKey("diagnostics"): return
  let uri = params["uri"].getStr()
  let diagCount = if params["diagnostics"].kind == JArray: params["diagnostics"].len else: 0
  stderr.writeLine("[app] handleDiagnostics: uri=" & uri & " count=" & $diagCount)

  # Normalize URI for comparison (remove file:// prefix and decode)
  let normalizedUri = decodeFileUri(uri)

  # Find if this file is open in any buffer
  var targetIdx = -1
  for i, b in app.buffers:
    if b.path == normalizedUri:
      targetIdx = i
      stderr.writeLine("[app] handleDiagnostics: matched buffer " & $i & " path=" & b.path)
      break

  # Parse all diagnostic entries (always do this, even for closed files)
  var parsedEntries: seq[DiagnosticEntry] = @[]
  let diagnostics = params["diagnostics"]
  if diagnostics.kind == JArray:
    for diag in diagnostics:
      if not diag.hasKey("range"): continue
      let range = diag["range"]
      let startLine = range["start"]["line"].getInt()
      let startChar = range["start"]["character"].getInt()
      let severity = if diag.hasKey("severity"): diag["severity"].getInt() else: SeverityError
      let message  = if diag.hasKey("message"): diag["message"].getStr() else: ""
      let source   = if diag.hasKey("source"): diag["source"].getStr() else: ""
      parsedEntries.add(DiagnosticEntry(
        uri:      uri,
        severity: severity,
        message:  message,
        source:   source,
        line:     startLine,
        col:      startChar
      ))

  # Always update the diagnostics panel store so users can browse all project
  # diagnostics, even for files that aren't currently open.
  app.diagPanel.update(uri, parsedEntries)

  # Apply markers only for open buffers
  if targetIdx >= 0:
    let text = app.buffers[targetIdx].ed.fullText()
    # Precompute line-start offsets to avoid O(lines) scans per diagnostic
    var lineStarts = @[0]
    for i, ch in text:
      if ch == '\n':
        lineStarts.add(i + 1)
    proc offsetFast(ls: seq[int]; line, col, maxLen: int): int =
      if line >= 0 and line < ls.len: result = ls[line] + col
      elif line < 0: result = col
      else: result = ls[^1] + col
      if result < 0: result = 0
      if result > maxLen: result = maxLen

    var diagMarkers: seq[tuple[a, b: int, color: screen.Color]] = @[]
    var diagLines: seq[int] = @[]
    if diagnostics.kind == JArray:
      for diag in diagnostics:
        if not diag.hasKey("range"): continue
        let range = diag["range"]
        if not range.hasKey("start") or not range.hasKey("end"): continue
        let start = range["start"]
        let `end` = range["end"]
        if not start.hasKey("line") or not start.hasKey("character"): continue
        if not `end`.hasKey("line") or not `end`.hasKey("character"): continue
        let startLine = start["line"].getInt()
        let startChar = start["character"].getInt()
        let endLine = `end`["line"].getInt()
        let endChar = `end`["character"].getInt()
        let a = offsetFast(lineStarts, startLine, startChar, text.len)
        let b = max(a, offsetFast(lineStarts, endLine, endChar, text.len) - 1)
        if b < a:
          diagMarkers.add((a, a, color(243, 139, 168, 80)))
        else:
          diagMarkers.add((a, b, color(243, 139, 168, 80)))
        diagLines.add(startLine)

    app.lastDiagLines[targetIdx] = diagLines
    app.bufferMarkers[targetIdx].setMarkers(msDiagnostic, diagMarkers)
    applyMarkers(app.buffers[targetIdx].ed, app.bufferMarkers[targetIdx])
    applyLineDecorations(app, targetIdx)


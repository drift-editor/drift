## Language id mapping, LSP-server resolution, bracket matching.

proc langToString(lang: SourceLanguage): string =
  case lang
  of langNim: "NIM"
  of langCpp: "C++"
  of langCsharp: "C#"
  of langC: "C"
  of langJava: "JAVA"
  of langJs: "JS"
  of langXml: "XML"
  of langHtml: "HTML"
  of langConsole: "CONSOLE"
  of langPython: "PYTHON"
  of langRust: "RUST"
  of langMarkdown: "MARKDOWN"
  of langNone: "PLAIN"


proc lspServerForLanguage(app: App, lang: string): string =
  ## Resolve the configured LSP server for a language, falling back to the
  ## legacy single `lspServer` value for Nim or when the per-language table
  ## is empty.
  if lang.len == 0:
    return ""
  if app.config.lspServers.hasKey(lang):
    return app.config.lspServers[lang]
  if lang == "nim" and app.config.lspServer.len > 0:
    return app.config.lspServer
  return ""



proc findMatchingBracket(text: string; startOff: int): int =
  ## Return the byte offset of the bracket matching the one at or before startOff,
  ## or -1 if not found.
  if text.len == 0:
    return -1
  var off = startOff
  if off >= text.len:
    off = text.len - 1
  var ch = text[off]
  let openToClose = {'(': ')', '[': ']', '{': '}'}.toTable()
  let closeToOpen = {')': '(', ']': '[', '}': '{'}.toTable()
  var targetOpen = '\x00'
  var direction = 0
  if ch in openToClose:
    targetOpen = ch
    direction = 1
  elif ch in closeToOpen:
    targetOpen = closeToOpen[ch]
    direction = -1
  else:
    if off > 0:
      dec off
      ch = text[off]
      if ch in openToClose:
        targetOpen = ch
        direction = 1
      elif ch in closeToOpen:
        targetOpen = closeToOpen[ch]
        direction = -1
  if direction == 0:
    return -1
  let targetClose = if direction == 1: openToClose[targetOpen] else: ch
  if targetOpen == '\x00': return -1
  var depth = 1
  var i = off + direction
  while i >= 0 and i < text.len:
    let c = text[i]
    if c == targetOpen:
      inc depth
    elif c == targetClose:
      dec depth
      if depth == 0:
        return i
    i += direction
  return -1



proc updateBracketMatchMarkers(app: App) =
  ## Highlight the bracket under the cursor and its matching pair.
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    if app.lastBracketBuffer >= 0 and app.lastBracketBuffer < app.buffers.len:
      app.bufferMarkers[app.lastBracketBuffer].setMarkers(msBracketMatch, @[])
      applyMarkers(app.buffers[app.lastBracketBuffer].ed, app.bufferMarkers[app.lastBracketBuffer])
    app.lastBracketBuffer = -1
    app.lastBracketCursorOff = -1
    return

  let b = app.buffers[app.currentBuffer]
  if b.isImage:
    return
  let text = b.ed.fullText()
  let off = offsetAtLineCol(text, b.ed.currentLine, b.ed.currentCol)
  if app.lastBracketBuffer != app.currentBuffer or app.lastBracketCursorOff != off:
    # Clear previous buffer markers
    if app.lastBracketBuffer >= 0 and app.lastBracketBuffer < app.buffers.len and app.lastBracketBuffer != app.currentBuffer:
      app.bufferMarkers[app.lastBracketBuffer].setMarkers(msBracketMatch, @[])
      applyMarkers(app.buffers[app.lastBracketBuffer].ed, app.bufferMarkers[app.lastBracketBuffer])

    var markers: seq[tuple[a, b: int, color: uirelays.Color]] = @[]
    let matchOff = findMatchingBracket(text, off)
    if matchOff >= 0:
      let accent = currentTheme.getColor(tcAccent)
      markers.add((off, off + 1, accent))
      markers.add((matchOff, matchOff + 1, accent))
    app.bufferMarkers[app.currentBuffer].setMarkers(msBracketMatch, markers)
    applyMarkers(app.buffers[app.currentBuffer].ed, app.bufferMarkers[app.currentBuffer])
    app.lastBracketBuffer = app.currentBuffer
    app.lastBracketCursorOff = off


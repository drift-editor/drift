## Document model: buffers, files, diff view, recent files, breakpoints.

# Forward declarations (bodies defined below or in other included files) so
# earlier procs can call them.
proc updateBreakpointMarkers(app: App; idx: int)
proc loadDiffContent(app: App; path: string; staged: bool)
proc lspExeFor(serverName: string): string
proc saveBuffer(app: App, idx: int; silent: bool = false): bool

proc showWelcome*(app: App) =
  app.screen = asWelcome
  app.welcomeScreen.show()


proc hideWelcome*(app: App) =
  app.screen = asWorkspace
  app.welcomeScreen.hide()


proc switchBuffer(app: App, idx: int) =
  if idx >= 0 and idx < app.buffers.len:
    app.currentBuffer = idx
    app.updateStatus()
    app.updateTitle()
    app.updateBreakpointMarkers(idx)
    # Update tab bar active state
    discard app.tabBar.setActiveTab($idx)
    # Hide welcome screen when switching to a buffer
    if app.screen == asWelcome:
      app.hideWelcome()
    # If switching to a diff buffer, refresh its content
    let b = app.buffers[idx]
    if b.diffPath.len > 0:
      app.loadDiffContent(b.diffPath, b.diffStaged)


proc closeBuffer(app: App, idx: int) =
  if idx < 0 or idx >= app.buffers.len:
    return

  # Remember closed tab so it can be reopened.
  let b = app.buffers[idx]
  if b.path.len > 0 and app.config.closedTabHistorySize > 0:
    app.closedTabs.add(ClosedTabInfo(path: b.path, line: b.ed.currentLine, col: b.ed.currentCol))
    if app.closedTabs.len > app.config.closedTabHistorySize:
      app.closedTabs.delete(0)

  # Notify LSP that the document is closed (keeps diagnostics in panel
  # for the user to browse even after the file is closed).
  let closedPath = app.buffers[idx].path
  if closedPath.len > 0 and app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    app.lspThread.notifyDidClose(closedPath)
  
  # Note: uirelays backends do not implement freeImage (drawRelays.freeImage
  # is nil), so we skip it to avoid SIGSEGV. Images are small and released
  # on process exit anyway.
  app.buffers.delete(idx)
  app.bufferMarkers.delete(idx)
  app.lastColorScanCacheIds.delete(idx)
  app.lastDiagLines.delete(idx)
  app.lastDiffLines.delete(idx)
  app.bufferLines.delete(idx)
  if app.buffers.len == 0:
    app.currentBuffer = -1
  else:
    app.switchBuffer(min(idx, app.buffers.high))
  # Rebuild tabs
  app.tabBar.clearTabs()
  for i, b in app.buffers:
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    discard app.tabBar.addTab($i, name)
  if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
    discard app.tabBar.setActiveTab($app.currentBuffer)


proc showDiffView*(app: App; path: string; staged: bool = false) =
  ## Open a split diff view as a new tab.
  let repoRoot = if app.gitPanel.currentPath.len > 0: app.gitPanel.currentPath else: getCurrentDir()
  if not gitcmd.isGitRepository(repoRoot):
    discard app.notificationManager.warning("Not a git repository")
    return
  # Reuse existing diff buffer for this file if present
  for i, b in app.buffers:
    if b.diffPath == path and b.diffStaged == staged:
      app.switchBuffer(i)
      return
  # Create a new diff buffer
  var ed = createSynEdit(app.font, app.editorTheme())
  app.buffers.add(Buffer(
    ed: ed, path: path, readOnly: true,
    diffPath: path, diffStaged: staged))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  let idx = app.buffers.high
  discard app.tabBar.addTab($idx, path.extractFilename)
  app.switchBuffer(idx)
  app.loadDiffContent(path, staged)
  if app.tooltip.visible: app.tooltip.hideTooltip()


proc hideDiffView*(app: App) =
  discard


proc addRecentFile(app: App, path: string) =
  app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = false)
  saveRecentFiles(app.recentFiles)
  app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)


proc addRecentFolder*(app: App, path: string) =
  app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = true)
  saveRecentFiles(app.recentFiles)
  app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)


proc offsetAtPos(text: string; line, col: int): int =
  var currLine = 0
  var currCol = 0
  var i = 0
  while i < text.len:
    if currLine == line and currCol == col:
      return i
    if text[i] == '\n':
      inc currLine
      currCol = 0
    else:
      inc currCol
    inc i
  return text.len


proc bufferPosToLineCol(text: string; pos: int): tuple[line, col: int] =
  if pos <= 0:
    return (0, 0)
  if pos >= text.len:
    result.line = countLines(text) - 1
    var lastNl = -1
    for i in 0 ..< text.len:
      if text[i] == '\n':
        lastNl = i
    result.col = text.len - lastNl - 1
    return
  result.line = countLines(text[0 ..< pos]) - 1
  var lastNl = -1
  for i in 0 ..< pos:
    if text[i] == '\n':
      lastNl = i
  result.col = pos - lastNl - 1


proc applyLineDecorations(app: App; idx: int) =
  app.buffers[idx].ed.clearLineDecorations()
  for line in app.lastDiagLines[idx]:
    app.buffers[idx].ed.setLineDecoration(line, color(243, 139, 168))
  for dl in app.lastDiffLines[idx]:
    case dl.kind
    of 'A':
      app.buffers[idx].ed.setLineDecoration(dl.line, currentTheme.getColor(tcSuccess))
    of 'M':
      app.buffers[idx].ed.setLineDecoration(dl.line, currentTheme.getColor(tcWarning))
    else:
      discard


proc openBuffer(app: App, path: string): int =
  for i, b in app.buffers:
    if b.path == path:
      app.switchBuffer(i)
      return i
  # Image files bypass binary check
  let isImg = path.len > 0 and isImageFile(path)
  if path.len > 0 and not isImg and isBinaryFile(path):
    return -1

  if isImg:
    let img = loadImage(path)
    if img.int == 0:
      discard app.notificationManager.error("Failed to load image: " & path.extractFilename)
      return -1
    # Get image dimensions via pixie
    var imgW, imgH: int
    try:
      let pixieImg = readImage(path)
      imgW = pixieImg.width
      imgH = pixieImg.height
    except CatchableError:
      imgW = 0
      imgH = 0
    var ed = createSynEdit(app.font, app.editorTheme())
    app.buffers.add(Buffer(
      ed: ed, path: path, isImage: true, image: img,
      imageWidth: imgW, imageHeight: imgH))
    app.bufferMarkers.add(initBufferMarkers())
    app.lastColorScanCacheIds.add(0)
    app.lastDiagLines.add(@[])
    app.lastDiffLines.add(@[])
    app.bufferLines.add(@[])
    result = app.buffers.high
    let name = path.extractFilename
    discard app.tabBar.addTab($result, name)
    app.switchBuffer(result)
    app.buffers[result].lastSaveTick = getTicks()
    return result

  var ed = createSynEdit(app.font, app.editorTheme())
  ed.showLineNumbers = app.config.showLineNumbers
  ed.lang = fileExtToLanguage(path.splitFile.ext)
  ed.tabSize = app.config.tabSize
  if fileExists(path):
    try:
      ed.loadFromFile(path)
    except CatchableError as err:
      discard app.notificationManager.error("Failed to load " & path.extractFilename & ": " & err.msg)
  app.buffers.add(Buffer(ed: ed, path: path))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  result = app.buffers.high
  if path.len > 0:
    app.lastDiffLines[result] = getDiffLines(path)
  let name = if path.len > 0: path.extractFilename else: "untitled"
  discard app.tabBar.addTab($result, name)
  app.switchBuffer(result)
  app.buffers[result].lastSaveTick = getTicks()

  # Start LSP for supported languages
  let lang = languageIdFor(path)
  let server = app.lspServerForLanguage(lang)
  if server.len > 0:
    if app.lspThread.isNil and not app.lspStarting:
      stderr.writeLine("[app] starting LSP thread: " & lspExeFor(server) & " language: " & lang)
      app.lspServer = server
      app.lspLanguage = lang
      app.lspThread = newLSPThread(lspExeFor(server), lang, app.config.lspConfig)
      app.lspStarting = true
    elif app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
      app.lspThread.notifyDidOpen(path, ed.fullText())


proc newBuffer(app: App) =
  var ed = createSynEdit(app.font, app.editorTheme())
  ed.showLineNumbers = app.config.showLineNumbers
  ed.lang = langNim
  ed.tabSize = app.config.tabSize
  app.buffers.add(Buffer(ed: ed, path: "", isImage: false))
  app.bufferMarkers.add(initBufferMarkers())
  app.lastColorScanCacheIds.add(0)
  app.lastDiagLines.add(@[])
  app.lastDiffLines.add(@[])
  app.bufferLines.add(@[])
  let idx = app.buffers.high
  discard app.tabBar.addTab($idx, "untitled")
  app.switchBuffer(idx)
  app.buffers[idx].lastSaveTick = getTicks()


proc saveCurrentBuffer(app: App): bool =
  saveBuffer(app, app.currentBuffer)


proc saveAsDialog*(app: App) =
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    return
  let defaultName = if app.buffers[app.currentBuffer].path.len > 0:
                      app.buffers[app.currentBuffer].path.extractFilename
                    else: "untitled.nim"
  var ext = defaultName.splitFile.ext
  if ext.len > 0 and ext[0] == '.': ext = ext[1..^1]
  let di = DialogInfo(kind: dkSaveFile, title: "Save File", extension: ext)
  let res = show(di)
  if res.isNone: return
  let path = res.get()
  app.buffers[app.currentBuffer].path = path
  try:
    app.buffers[app.currentBuffer].ed.saveToFile(path)
  except CatchableError as err:
    discard app.notificationManager.error("Failed to save " & path.extractFilename & ": " & err.msg)
    return
  discard app.notificationManager.success("Saved " & path.extractFilename)
  app.lastDiffLines[app.currentBuffer] = getDiffLines(path)
  app.buffers[app.currentBuffer].lastSaveTick = getTicks()
  app.updateTitle()
  app.updateStatus()
  app.tabBar.clearTabs()
  for i, b in app.buffers:
    let name = if b.path.len > 0: b.path.extractFilename else: "untitled"
    discard app.tabBar.addTab($i, name)
  discard app.tabBar.setActiveTab($app.currentBuffer)
  # Notify LSP about the new file path
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    let lang = languageIdFor(path)
    if app.lspServerForLanguage(lang).len > 0:
      let text = app.buffers[app.currentBuffer].ed.fullText()
      app.lspThread.notifyDidOpen(path, text)


proc openFileDialog*(app: App): bool =
  let di = DialogInfo(kind: dkOpenFile, title: "Open File")
  let res = show(di)
  if res.isSome:
    let path = res.get()
    if fileExists(path):
      discard app.openBuffer(path)
      app.addRecentFile(path)
      return true
  false


proc openFolderDialog*(app: App): bool =
  let di = DialogInfo(kind: dkSelectFolder, title: "Open Folder")
  let res = show(di)
  if res.isSome:
    let path = res.get()
    if dirExists(path):
      app.fileExplorer.setRootPath(path)
      app.gitPanel.currentPath = path
      app.gitPanel.updateRepository()
      app.recentFiles = addToRecentFiles(app.recentFiles, path, isFolder = true)
      saveRecentFiles(app.recentFiles)
      app.welcomeScreen.updateRecentFilesWithPins(recentItems(app.recentFiles), app.config.pinnedRecentFiles)
      return true
  false

# Public API


proc loadDiffContent(app: App; path: string; staged: bool) =
  ## Fetch git versions and populate the shared diff view.
  let repoRoot = if app.gitPanel.currentPath.len > 0: app.gitPanel.currentPath else: getCurrentDir()
  let (oldOutput, oldExit) = gitcmd.execGitCommand(
    if staged: @["show", ":" & path] else: @["show", "HEAD:" & path],
    repoRoot)
  let oldText = if oldExit == 0: oldOutput else: ""
  let fullPath = repoRoot / path
  var newText = ""
  if fileExists(fullPath):
    try:
      newText = readFile(fullPath)
    except CatchableError:
      discard
  if app.diffView == nil:
    app.diffView = newDiffView(app.font, driftSyneditTheme())
    app.diffView.onClose = proc() =
      if app.currentBuffer >= 0 and app.currentBuffer < app.buffers.len:
        if app.buffers[app.currentBuffer].diffPath.len > 0:
          app.closeBuffer(app.currentBuffer)
  app.diffView.oldPath = path
  app.diffView.newPath = path
  app.diffView.setText(oldText, newText)
  app.diffView.setLabels("Previous", "Current")


proc updateBreakpointMarkers(app: App; idx: int) =
  if idx < 0 or idx >= app.buffers.len or idx >= app.bufferMarkers.len:
    return
  let path = app.buffers[idx].path
  var bpMarkers: seq[tuple[a, b: int, color: screen.Color]] = @[]
  if path.len > 0:
    for bp in app.breakpoints:
      if bp.path == path and bp.enabled:
        let lineStart = offsetAtPos(app.buffers[idx].ed.fullText(), bp.line, 0)
        bpMarkers.add((lineStart, lineStart, screen.color(220, 90, 90, 255)))
  app.bufferMarkers[idx].setMarkers(msBreakpoint, bpMarkers)
  applyMarkers(app.buffers[idx].ed, app.bufferMarkers[idx])

proc saveBuffer(app: App, idx: int; silent: bool = false): bool =
  ## Save a specific buffer by index. Returns true on success.
  if idx < 0 or idx >= app.buffers.len:
    return false
  let b = app.buffers[idx]
  if b.path.len == 0:
    return false
  if b.isImage:
    if not silent:
      discard app.notificationManager.info("Images are read-only")
    return false
  try:
    app.buffers[idx].ed.saveToFile(b.path)
  except CatchableError as err:
    if not silent:
      discard app.notificationManager.error("Failed to save " & b.path.extractFilename & ": " & err.msg)
    return false
  if not silent:
    discard app.notificationManager.success("Saved " & b.path.extractFilename)
  app.lastDiffLines[idx] = getDiffLines(b.path)
  app.buffers[idx].lastSaveTick = getTicks()
  if app.lspThread != nil and app.lspThread.isReady.load(moAcquire):
    let lang = languageIdFor(b.path)
    if app.lspServerForLanguage(lang).len > 0:
      let text = app.buffers[idx].ed.fullText()
      app.lspThread.notifyDidChange(b.path, text)
  return true


proc checkAutoSave(app: App) =
  ## Save dirty buffers after the configured auto-save delay.
  if app.config.autoSave != "afterDelay":
    return
  let now = getTicks()
  for i in 0 ..< app.buffers.len:
    let b = app.buffers[i]
    if b.path.len == 0 or b.isImage or b.diffPath.len > 0:
      continue
    if not b.ed.changed:
      continue
    if b.lastSaveTick >= b.lastEditTick:
      continue
    if now - b.lastEditTick > app.config.autoSaveDelayMs:
      discard app.saveBuffer(i, silent = true)


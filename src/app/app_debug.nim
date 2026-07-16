## Debug (DAP) control procs: start/stop/step, breakpoints.
##
## `include`d into app.nim (App type already defined) so these `proc`s can
## reference `App` directly without a circular import.

# Public API

proc continueDebugging*(app: App) =
  if not app.debugState.canContinue: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestContinue(app.debugStopThreadId)

proc startDebugging*(app: App) =
  if not app.debugState.canStart:
    discard app.notificationManager.warning("A debug session is already active")
    return
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len:
    discard app.notificationManager.error("No file open to debug")
    return
  let b = app.buffers[app.currentBuffer]
  if b.path.len == 0:
    discard app.notificationManager.error("Save the file before debugging")
    return
  let exePath = b.path.changeFileExt("")
  if not fileExists(exePath):
    discard app.notificationManager.info("Building " & b.path.extractFilename & "...")
    let buildRes = execCmdEx("nim c --debugger:native \"" & b.path & "\"")
    if buildRes.exitCode != 0:
      discard app.notificationManager.error("Build failed")
      app.debugPanel.addOutput(buildRes.output)
      app.showTerminal = true
      app.bottomPanelTab = "debug"
      return
  app.dapThread = newDAPThread(app.config.dapServer)
  app.debugState = dssStarting
  app.debugStopThreadId = 0
  app.debugPanel.clear()
  app.showTerminal = true
  app.bottomPanelTab = "debug"
  discard app.notificationManager.info("Debug session started")

proc startOrContinueDebugging*(app: App) =
  if app.debugState.canContinue:
    app.continueDebugging()
  else:
    app.startDebugging()

proc stopDebugging*(app: App) =
  if not app.debugState.canStop: return
  if app.dapThread != nil:
    app.dapThread.requestDisconnect()
    app.dapThread.shutdown()
    app.dapThread = nil
  app.debugState = dssOff
  app.debugStopThreadId = 0
  discard app.notificationManager.info("Debug session stopped")

proc stepOverDebugging*(app: App) =
  if not app.debugState.canStep: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestNext(app.debugStopThreadId)

proc stepIntoDebugging*(app: App) =
  if not app.debugState.canStep: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestStepIn(app.debugStopThreadId)

proc stepOutDebugging*(app: App) =
  if not app.debugState.canStep: return
  if app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    app.debugState = dssRunning
    app.dapThread.requestStepOut(app.debugStopThreadId)

proc toggleBreakpoint*(app: App) =
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len: return
  let b = app.buffers[app.currentBuffer]
  if b.path.len == 0: return
  let line = b.ed.currentLine
  var foundIdx = -1
  for i, bp in app.breakpoints:
    if bp.path == b.path and bp.line == line:
      foundIdx = i
      break
  if foundIdx >= 0:
    app.breakpoints.del(foundIdx)
  else:
    app.breakpoints.add((path: b.path, line: line, enabled: true))
  app.updateBreakpointMarkers(app.currentBuffer)
  # Update breakpoints in running session
  if app.debugState.isActive and app.dapThread != nil and app.dapThread.isReady.load(moAcquire):
    var lines: seq[int] = @[]
    for bp in app.breakpoints:
      if bp.path == b.path and bp.enabled:
        lines.add(bp.line.toDAPLine())
    app.dapThread.requestSetBreakpoints(b.path, lines)


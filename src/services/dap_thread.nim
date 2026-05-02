import std/[options, json, os]
import ../channel_spsc
import chronos
import dap_client

type
  DAPMessageKind* = enum
    dmkInitialize
    dmkLaunch
    dmkSetBreakpoints
    dmkConfigurationDone
    dmkStackTrace
    dmkScopes
    dmkVariables
    dmkContinue
    dmkNext
    dmkStepIn
    dmkStepOut
    dmkPause
    dmkDisconnect
    dmkShutdown
    dmkReady
    dmkError
    dmkStopped
    dmkOutput
    dmkTerminated
    dmkStackTraceResponse
    dmkVariablesResponse

  DAPMessage* = object
    kind*: DAPMessageKind
    str1*: string
    str2*: string
    int1*: int
    int2*: int
    int3*: int
    jsonData*: JsonNode
    lines*: seq[int]

  DAPThread* = ref object
    reqChan: SPSChannel[DAPMessage]
    respChan: SPSChannel[DAPMessage]
    thread: Thread[DAPThread]
    isReady*: bool

proc sendResponse(t: DAPThread, msg: DAPMessage) {.inline.} =
  if not t.respChan.isClosed and not channel_spsc.trySend(t.respChan, msg):
    stderr.writeLine("[dap-thread] WARNING: dropped response, channel full (kind=" & $msg.kind & ")")

proc asyncSetBreakpoints(client: DAPClient; path: string; lines: seq[int]) {.async.} =
  discard await requestSetBreakpoints(client, path, lines)

proc dapThreadProc(t: DAPThread) {.thread.} =
  var initialMsg: DAPMessage
  if channel_spsc.tryReceive(t.reqChan, initialMsg):
    let adapterName = initialMsg.str1
    stderr.writeLine("[dap-thread] starting adapter: " & adapterName)
    var client: DAPClient = nil
    var stoppedBuffer: seq[tuple[reason: string, threadId: int, description: string]] = @[]
    var outputBuffer: seq[tuple[category: string, output: string]] = @[]
    var terminatedBuffer: seq[int] = @[]

    proc runEventLoop() {.async.} =
      try:
        client = await startDAP(adapterName)
        stderr.writeLine("[dap-thread] startDAP returned, ready=" & $client.isReady)
        if client.isReady:
          client.setStoppedCallback(proc(reason: string; threadId: int; description: string) {.gcsafe.} =
            stoppedBuffer.add((reason, threadId, description))
          )
          client.setOutputCallback(proc(category: string; output: string) {.gcsafe.} =
            outputBuffer.add((category, output))
          )
          client.setTerminatedCallback(proc() {.gcsafe.} =
            terminatedBuffer.add(0)
          )
          client.ensureReadLoop()
          t.isReady = true
          t.sendResponse(DAPMessage(kind: dmkReady, str1: "Ready"))
        else:
          t.sendResponse(DAPMessage(kind: dmkError, str1: client.errorMsg))
          return
      except CatchableError as e:
        stderr.writeLine("[dap-thread] startDAP exception: " & e.msg)
        t.sendResponse(DAPMessage(kind: dmkError, str1: e.msg))
        return

      var stackTraceFuture: Future[JsonNode] = nil
      var variablesFuture: Future[JsonNode] = nil
      var stackTraceRequestMeta: Option[DAPMessage] = none(DAPMessage)
      var variablesRequestMeta: Option[DAPMessage] = none(DAPMessage)
      var idleCount = 0
      const FastSleepMs = 1
      const SlowSleepMs = 16
      const IdleThreshold = 2

      var running = true
      while running and not t.reqChan.isClosed:
        var hadWork = false
        var reqBatch: seq[DAPMessage] = @[]
        var tmp: DAPMessage

        # Drain entire reqChan in one go
        while channel_spsc.tryReceive(t.reqChan, tmp):
          reqBatch.add(tmp)
          hadWork = true

        if hadWork:
          idleCount = 0
          var lastLaunch: Option[DAPMessage] = none(DAPMessage)
          var lastSetBreakpoints: Option[DAPMessage] = none(DAPMessage)
          var lastConfigDone: Option[DAPMessage] = none(DAPMessage)
          var lastStackTrace: Option[DAPMessage] = none(DAPMessage)
          var lastVariables: Option[DAPMessage] = none(DAPMessage)
          var lastContinue: Option[DAPMessage] = none(DAPMessage)
          var lastNext: Option[DAPMessage] = none(DAPMessage)
          var lastStepIn: Option[DAPMessage] = none(DAPMessage)
          var lastStepOut: Option[DAPMessage] = none(DAPMessage)
          var lastPause: Option[DAPMessage] = none(DAPMessage)
          var lastDisconnect: Option[DAPMessage] = none(DAPMessage)

          for m in reqBatch:
            if not running: break
            case m.kind
            of dmkLaunch: lastLaunch = some(m)
            of dmkSetBreakpoints: lastSetBreakpoints = some(m)
            of dmkConfigurationDone: lastConfigDone = some(m)
            of dmkStackTrace: lastStackTrace = some(m)
            of dmkVariables: lastVariables = some(m)
            of dmkContinue: lastContinue = some(m)
            of dmkNext: lastNext = some(m)
            of dmkStepIn: lastStepIn = some(m)
            of dmkStepOut: lastStepOut = some(m)
            of dmkPause: lastPause = some(m)
            of dmkDisconnect: lastDisconnect = some(m)
            of dmkShutdown: running = false
            else: discard

          if running and lastLaunch.isSome:
            let l = lastLaunch.get()
            asyncSpawn requestLaunch(client, l.str1, args = @[], cwd = l.str2, stopOnEntry = l.int1 != 0)
          if running and lastSetBreakpoints.isSome:
            let b = lastSetBreakpoints.get()
            asyncSpawn asyncSetBreakpoints(client, b.str1, b.lines)
          if running and lastConfigDone.isSome:
            asyncSpawn requestConfigurationDone(client)
          if running and lastStackTrace.isSome:
            let s = lastStackTrace.get()
            stackTraceFuture = requestStackTrace(client, s.int1)
            stackTraceRequestMeta = some(s)
          if running and lastVariables.isSome:
            let v = lastVariables.get()
            variablesFuture = requestVariables(client, v.int1)
            variablesRequestMeta = some(v)
          if running and lastContinue.isSome:
            let c = lastContinue.get()
            asyncSpawn requestContinue(client, c.int1)
          if running and lastNext.isSome:
            let n = lastNext.get()
            asyncSpawn requestNext(client, n.int1)
          if running and lastStepIn.isSome:
            let s = lastStepIn.get()
            asyncSpawn requestStepIn(client, s.int1)
          if running and lastStepOut.isSome:
            let s = lastStepOut.get()
            asyncSpawn requestStepOut(client, s.int1)
          if running and lastPause.isSome:
            let p = lastPause.get()
            asyncSpawn requestPause(client, p.int1)
          if running and lastDisconnect.isSome:
            asyncSpawn requestDisconnect(client)
        else:
          idleCount += 1

        var hadFlushWork = false

        if stackTraceFuture != nil and stackTraceFuture.finished:
          hadFlushWork = true
          let resp = stackTraceFuture.read()
          let reqMeta = if stackTraceRequestMeta.isSome: stackTraceRequestMeta.get() else: DAPMessage(kind: dmkStackTrace)
          t.sendResponse(DAPMessage(
            kind: dmkStackTraceResponse,
            int1: reqMeta.int1,
            jsonData: resp
          ))
          stackTraceFuture = nil
          stackTraceRequestMeta = none(DAPMessage)

        if variablesFuture != nil and variablesFuture.finished:
          hadFlushWork = true
          let resp = variablesFuture.read()
          let reqMeta = if variablesRequestMeta.isSome: variablesRequestMeta.get() else: DAPMessage(kind: dmkVariables)
          t.sendResponse(DAPMessage(
            kind: dmkVariablesResponse,
            int1: reqMeta.int1,
            jsonData: resp
          ))
          variablesFuture = nil
          variablesRequestMeta = none(DAPMessage)

        if stoppedBuffer.len > 0 or outputBuffer.len > 0 or terminatedBuffer.len > 0:
          hadFlushWork = true
          var stops = stoppedBuffer
          var outputs = outputBuffer
          var terms = terminatedBuffer
          stoppedBuffer = @[]
          outputBuffer = @[]
          terminatedBuffer = @[]
          for s in stops:
            t.sendResponse(DAPMessage(kind: dmkStopped, str1: s.reason, int1: s.threadId, str2: s.description))
          for o in outputs:
            t.sendResponse(DAPMessage(kind: dmkOutput, str1: o.category, str2: o.output))
          for _ in terms:
            t.sendResponse(DAPMessage(kind: dmkTerminated))

        if not hadWork and not hadFlushWork:
          let sleepMs = if idleCount < IdleThreshold: FastSleepMs else: SlowSleepMs
          await sleepAsync(chronos.timer.milliseconds(sleepMs))

      try:
        if client != nil and client.isReady:
          await stopDAP(client)
      except CatchableError:
        discard

    waitFor runEventLoop()

proc newDAPThread*(adapterName: string = "nim_debug_adapter"): DAPThread =
  result = DAPThread()
  result.reqChan = newSPSChannel[DAPMessage](64)
  result.respChan = newSPSChannel[DAPMessage](256)
  createThread(result.thread, dapThreadProc, result)
  let initMsg = DAPMessage(kind: dmkInitialize, str1: adapterName)
  if not channel_spsc.trySend(result.reqChan, initMsg):
    stderr.writeLine("[dap-thread] FATAL: failed to send initial adapter name to DAP thread")

proc getResponse*(t: DAPThread): Option[DAPMessage] =
  var msg: DAPMessage
  if channel_spsc.tryReceive(t.respChan, msg): some(msg) else: none(DAPMessage)

proc queueRequest(t: DAPThread, msg: DAPMessage) {.inline.} =
  if not channel_spsc.trySend(t.reqChan, msg):
    stderr.writeLine("[dap-thread] WARNING: dropped request, channel full (kind=" & $msg.kind & ")")

proc requestLaunch*(t: DAPThread; program: string; cwd: string = ""; stopOnEntry: bool = false) =
  t.queueRequest(DAPMessage(kind: dmkLaunch, str1: program, str2: cwd, int1: if stopOnEntry: 1 else: 0))

proc requestSetBreakpoints*(t: DAPThread; path: string; lines: seq[int]) =
  t.queueRequest(DAPMessage(kind: dmkSetBreakpoints, str1: path, lines: lines))

proc requestConfigurationDone*(t: DAPThread) =
  t.queueRequest(DAPMessage(kind: dmkConfigurationDone))

proc requestStackTrace*(t: DAPThread; threadId: int) =
  t.queueRequest(DAPMessage(kind: dmkStackTrace, int1: threadId))

proc requestVariables*(t: DAPThread; variablesReference: int) =
  t.queueRequest(DAPMessage(kind: dmkVariables, int1: variablesReference))

proc requestContinue*(t: DAPThread; threadId: int) =
  t.queueRequest(DAPMessage(kind: dmkContinue, int1: threadId))

proc requestNext*(t: DAPThread; threadId: int) =
  t.queueRequest(DAPMessage(kind: dmkNext, int1: threadId))

proc requestStepIn*(t: DAPThread; threadId: int) =
  t.queueRequest(DAPMessage(kind: dmkStepIn, int1: threadId))

proc requestStepOut*(t: DAPThread; threadId: int) =
  t.queueRequest(DAPMessage(kind: dmkStepOut, int1: threadId))

proc requestPause*(t: DAPThread; threadId: int) =
  t.queueRequest(DAPMessage(kind: dmkPause, int1: threadId))

proc requestDisconnect*(t: DAPThread) =
  t.queueRequest(DAPMessage(kind: dmkDisconnect))

proc shutdown*(t: DAPThread) =
  if not channel_spsc.trySend(t.reqChan, DAPMessage(kind: dmkShutdown)):
    t.reqChan.close()
  for i in 0..<200:
    if not t.thread.running: break
    sleep(10)
  t.reqChan.close()
  t.respChan.close()

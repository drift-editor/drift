import std/[options, json, os]
import ../channel_spsc
import chronos
import lsp_client
import ../core/types

type
  LSPMessageKind* = enum
    lmkHover
    lmkDefinition
    lmkDidOpen
    lmkDidChange
    lmkCancelHover
    lmkShutdown
    lmkDiagnostics
    lmkShowMessage
    lmkReady
    lmkError

  LSPMessage* = object
    kind*: LSPMessageKind
    str1*: string
    str2*: string
    int1*: int
    int2*: int
    hoverReqId*: int
    locations*: seq[Location]
    hoverText*: Option[string]
    jsonData*: JsonNode  # For passing config

  LSPThread* = ref object
    reqChan: SPSChannel[LSPMessage]
    respChan: SPSChannel[LSPMessage]
    thread: Thread[LSPThread]
    isReady*: bool

proc sendResponse(t: LSPThread, msg: LSPMessage) {.inline.} =
  if not t.respChan.isClosed and not channel_spsc.trySend(t.respChan, msg):
    stderr.writeLine("[lsp-thread] WARNING: dropped response, channel full (kind=" & $msg.kind & ")")

proc lspThreadProc(t: LSPThread) {.thread.} =
  var initialMsg: LSPMessage
  if channel_spsc.tryReceive(t.reqChan, initialMsg):
    let serverName = initialMsg.str1
    let initOptions = if initialMsg.jsonData != nil: initialMsg.jsonData else: newJObject()
    stderr.writeLine("[lsp-thread] starting server: " & serverName)
    var client: LSPClient = nil
    var diagBuffer: seq[string] = @[]
    var msgBuffer: seq[tuple[msg: string, msgType: int]] = @[]

    proc runEventLoop() {.async.} =
      try:
        client = await startLSP("nim", serverName, initOptions)
        stderr.writeLine("[lsp-thread] startLSP returned, ready=" & $client.isReady)
        if client.isReady:
          client.setDiagnosticsCallback(proc(j: JsonNode) =
            let uri = if j.hasKey("params") and j["params"].hasKey("uri"): j["params"]["uri"].getStr() else: "?"
            let cnt = if j.hasKey("params") and j["params"].hasKey("diagnostics"): j["params"]["diagnostics"].len else: 0
            stderr.writeLine("[lsp-thread] diagnostics callback fired: uri=" & uri & " count=" & $cnt)
            diagBuffer.add($j)
          )
          client.setShowMessageCallback(proc(m: string, mt: int) =
            msgBuffer.add((m, mt))
          )
          client.ensureReadLoop()
          t.isReady = true
          t.sendResponse(LSPMessage(kind: lmkReady, str1: "Ready"))
        else:
          t.sendResponse(LSPMessage(kind: lmkError, str1: client.errorMsg))
          return
      except CatchableError as e:
        stderr.writeLine("[lsp-thread] startLSP exception: " & e.msg)
        t.sendResponse(LSPMessage(kind: lmkError, str1: e.msg))
        return

      var hoverFuture: Future[Option[string]] = nil
      var hoverRequestMeta: Option[LSPMessage] = none(LSPMessage)
      var definitionFuture: Future[seq[Location]] = nil
      var idleCount = 0
      const FastSleepMs = 1
      const SlowSleepMs = 16
      const IdleThreshold = 2

      var running = true
      while running and not t.reqChan.isClosed:
        var hadWork = false
        var reqBatch: seq[LSPMessage] = @[]
        var tmp: LSPMessage

        # Drain entire reqChan in one go
        while channel_spsc.tryReceive(t.reqChan, tmp):
          reqBatch.add(tmp)
          hadWork = true

        if hadWork:
          idleCount = 0
          var hasCancel = false
          var lastHover: Option[LSPMessage] = none(LSPMessage)
          var lastDef: Option[LSPMessage] = none(LSPMessage)

          for m in reqBatch:
            if not running: break
            case m.kind
            of lmkHover: lastHover = some(m)
            of lmkDefinition: lastDef = some(m)
            of lmkCancelHover: hasCancel = true
            of lmkShutdown: running = false
            of lmkDidOpen: asyncSpawn didOpen(client, m.str1, m.str2)
            of lmkDidChange: asyncSpawn didChange(client, m.str1, m.str2)
            else: discard

          if running and hasCancel:
            client.cancelHover()
            hoverFuture = nil
            hoverRequestMeta = none(LSPMessage)
          if running and lastDef.isSome:
            let d = lastDef.get()
            stderr.writeLine("[lsp-thread] processing definition request: " & d.str1 & " line=" & $d.int1 & " col=" & $d.int2)
            definitionFuture = definitionAsync(client, d.str1, d.int1, d.int2)
          if running and lastHover.isSome:
            let h = lastHover.get()
            stderr.writeLine("[lsp-thread] processing hover request: id=" & $h.hoverReqId & " " & h.str1 & " line=" & $h.int1 & " col=" & $h.int2)
            hoverFuture = hoverAsync(client, h.str1, h.int1, h.int2)
            hoverRequestMeta = some(h)
        else:
          idleCount += 1

        var hadFlushWork = false

        if hoverFuture != nil and hoverFuture.finished:
          hadFlushWork = true
          let text = hoverFuture.read()
          let reqMeta = if hoverRequestMeta.isSome: hoverRequestMeta.get() else: LSPMessage(kind: lmkHover)
          stderr.writeLine("[lsp-thread] hover response ready: id=" & $reqMeta.hoverReqId & " hasText=" & $text.isSome)
          t.sendResponse(LSPMessage(
            kind: lmkHover,
            str1: reqMeta.str1,
            int1: reqMeta.int1,
            int2: reqMeta.int2,
            hoverReqId: reqMeta.hoverReqId,
            hoverText: text
          ))
          hoverFuture = nil
          hoverRequestMeta = none(LSPMessage)

        if definitionFuture != nil and definitionFuture.finished:
          hadFlushWork = true
          let locs = definitionFuture.read()
          stderr.writeLine("[lsp-thread] definition response ready: locs=" & $locs.len)
          for i, loc in locs:
            stderr.writeLine("[lsp-thread]   loc[" & $i & "] uri=" & loc.uri & " line=" & $loc.range.start.line & " col=" & $loc.range.start.character)
          t.sendResponse(LSPMessage(kind: lmkDefinition, locations: locs))
          definitionFuture = nil

        if diagBuffer.len > 0 or msgBuffer.len > 0:
          hadFlushWork = true
          var diags = diagBuffer
          var msgs = msgBuffer
          diagBuffer = @[]
          msgBuffer = @[]
          for d in diags:
            t.sendResponse(LSPMessage(kind: lmkDiagnostics, str1: d))
          for m in msgs:
            t.sendResponse(LSPMessage(kind: lmkShowMessage, str1: m.msg, int1: m.msgType))

        if not hadWork and not hadFlushWork:
          let sleepMs = if idleCount < IdleThreshold: FastSleepMs else: SlowSleepMs
          await sleepAsync(chronos.timer.milliseconds(sleepMs))

      try:
        if client != nil and client.isReady:
          await stopLSP(client)
      except CatchableError:
        discard

    waitFor runEventLoop()

proc newLSPThread*(serverName: string = "minlsp", initOptions: JsonNode = nil): LSPThread =
  result = LSPThread()
  result.reqChan = newSPSChannel[LSPMessage](64)
  result.respChan = newSPSChannel[LSPMessage](256)
  createThread(result.thread, lspThreadProc, result)
  let opts = if initOptions != nil: initOptions else: newJObject()
  let initMsg = LSPMessage(kind: lmkReady, str1: serverName, jsonData: opts)
  if not channel_spsc.trySend(result.reqChan, initMsg):
    stderr.writeLine("[lsp-thread] FATAL: failed to send initial server name to LSP thread")

proc getResponse*(t: LSPThread): Option[LSPMessage] =
  var msg: LSPMessage
  if channel_spsc.tryReceive(t.respChan, msg): some(msg) else: none(LSPMessage)

proc queueRequest(t: LSPThread, msg: LSPMessage) {.inline.} =
  if not channel_spsc.trySend(t.reqChan, msg):
    if msg.kind != lmkCancelHover:
      stderr.writeLine("[lsp-thread] WARNING: dropped request, channel full (kind=" & $msg.kind & ")")

proc requestHover*(t: LSPThread; path: string; line, col: int; requestId: int = 0) =
  stderr.writeLine("[lsp-thread] requestHover queued: id=" & $requestId & " " & path & " line=" & $line & " col=" & $col)
  t.queueRequest(LSPMessage(kind: lmkHover, str1: path, int1: line, int2: col, hoverReqId: requestId))

proc requestDefinition*(t: LSPThread; path: string; line, col: int) =
  stderr.writeLine("[lsp-thread] requestDefinition queued: " & path & " line=" & $line & " col=" & $col)
  t.queueRequest(LSPMessage(kind: lmkDefinition, str1: path, int1: line, int2: col))

proc notifyDidOpen*(t: LSPThread; path, content: string) =
  t.queueRequest(LSPMessage(kind: lmkDidOpen, str1: path, str2: content))

proc notifyDidChange*(t: LSPThread; path, content: string) =
  t.queueRequest(LSPMessage(kind: lmkDidChange, str1: path, str2: content))

proc cancelHover*(t: LSPThread) =
  t.queueRequest(LSPMessage(kind: lmkCancelHover))

proc shutdown*(t: LSPThread) =
  if not channel_spsc.trySend(t.reqChan, LSPMessage(kind: lmkShutdown)):
    t.reqChan.close()
  for i in 0..<200:
    if not t.thread.running: break
    sleep(10)
  t.reqChan.close()
  t.respChan.close()

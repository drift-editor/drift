import std/[options, json, os, monotimes, tables]
import std/atomics
import ../channel_spsc
import chronos
import lsp_client
import ../core/types

type
  LSPMessageKind* = enum
    lmkHover
    lmkDefinition
    lmkFormat
    lmkRename
    lmkReferences
    lmkDocumentSymbols
    lmkWorkspaceSymbols
    lmkDidOpen
    lmkDidChange
    lmkDidClose
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
    range*: LSPRange
    locations*: seq[Location]
    symbols*: seq[LSPSymbol]
    hoverText*: Option[string]
    edits*: seq[LSPTextEdit]
    workspaceEdit*: LSPWorkspaceEdit
    jsonData*: JsonNode  # For passing config

  LSPThread* = ref object
    reqChan: SPSChannel[LSPMessage]
    respChan: SPSChannel[LSPMessage]
    thread: Thread[LSPThread]
    isReady*: Atomic[bool]

proc sendResponse(t: LSPThread, msg: LSPMessage) {.inline.} =
  if not t.respChan.isClosed and not channel_spsc.trySend(t.respChan, msg):
    stderr.writeLine("[lsp-thread] WARNING: dropped response, channel full (kind=" & $msg.kind & ")")

proc lspThreadProc(t: LSPThread) {.thread.} =
  var initialMsg: LSPMessage
  if channel_spsc.tryReceive(t.reqChan, initialMsg):
    let serverName = initialMsg.str1
    let language = if initialMsg.str2.len > 0: initialMsg.str2 else: "nim"
    let initOptions = if initialMsg.jsonData != nil: initialMsg.jsonData else: newJObject()
    stderr.writeLine("[lsp-thread] starting server: " & serverName & " language: " & language)
    var client: LSPClient = nil
    const MaxBufferSize = 200
    var diagBuffer: seq[JsonNode] = @[]
    var msgBuffer: seq[tuple[msg: string, msgType: int]] = @[]
    var lastDidChangeTime: Table[string, int64] = initTable[string, int64]()
    const DidChangeDebounceMs = 150
    template nowMs(): int64 = getMonoTime().ticks div 1_000_000

    proc runEventLoop() {.async.} =
      try:
        client = await startLSP(language, serverName, initOptions)
        stderr.writeLine("[lsp-thread] startLSP returned, ready=" & $client.isReady)
        if client.isReady:
          client.setDiagnosticsCallback(proc(j: JsonNode) =
            let uri = if j.hasKey("params") and j["params"].hasKey("uri"): j["params"]["uri"].getStr() else: "?"
            let cnt = if j.hasKey("params") and j["params"].hasKey("diagnostics"): j["params"]["diagnostics"].len else: 0
            stderr.writeLine("[lsp-thread] diagnostics callback fired: uri=" & uri & " count=" & $cnt)
            if diagBuffer.len >= MaxBufferSize:
              diagBuffer.delete(0)
            diagBuffer.add(j)
          )
          client.setShowMessageCallback(proc(m: string, mt: int) =
            if msgBuffer.len >= MaxBufferSize:
              msgBuffer.delete(0)
            msgBuffer.add((m, mt))
          )
          client.ensureReadLoop()
          t.isReady.store(true, moRelease)
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
      var formatFuture: Future[seq[LSPTextEdit]] = nil
      var formatRequestMeta: Option[LSPMessage] = none(LSPMessage)
      var renameFuture: Future[LSPWorkspaceEdit] = nil
      var renameRequestMeta: Option[LSPMessage] = none(LSPMessage)
      var referencesFuture: Future[seq[Location]] = nil
      var referencesRequestMeta: Option[LSPMessage] = none(LSPMessage)
      var documentSymbolsFuture: Future[seq[LSPSymbol]] = nil
      var documentSymbolsRequestMeta: Option[LSPMessage] = none(LSPMessage)
      var workspaceSymbolsFuture: Future[seq[LSPSymbol]] = nil
      var workspaceSymbolsRequestMeta: Option[LSPMessage] = none(LSPMessage)
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
          var lastFormat: Option[LSPMessage] = none(LSPMessage)
          var lastRename: Option[LSPMessage] = none(LSPMessage)
          var lastReferences: Option[LSPMessage] = none(LSPMessage)
          var lastDocumentSymbols: Option[LSPMessage] = none(LSPMessage)
          var lastWorkspaceSymbols: Option[LSPMessage] = none(LSPMessage)

          for m in reqBatch:
            if not running: break
            case m.kind
            of lmkHover: lastHover = some(m)
            of lmkDefinition: lastDef = some(m)
            of lmkFormat: lastFormat = some(m)
            of lmkRename: lastRename = some(m)
            of lmkReferences: lastReferences = some(m)
            of lmkDocumentSymbols: lastDocumentSymbols = some(m)
            of lmkWorkspaceSymbols: lastWorkspaceSymbols = some(m)
            of lmkCancelHover: hasCancel = true
            of lmkShutdown: running = false
            of lmkDidOpen: asyncSpawn didOpen(client, m.str1, m.str2)
            of lmkDidChange:
              let now = nowMs()
              if not lastDidChangeTime.hasKey(m.str1) or
                 now - lastDidChangeTime[m.str1] >= DidChangeDebounceMs:
                lastDidChangeTime[m.str1] = now
                asyncSpawn didChange(client, m.str1, m.str2)
            of lmkDidClose:
              lastDidChangeTime.del(m.str1)
              asyncSpawn didClose(client, m.str1)
            else: discard

          if running and hasCancel:
            client.cancelHover()
            hoverFuture = nil
            hoverRequestMeta = none(LSPMessage)
          if running and lastDef.isSome:
            let d = lastDef.get()
            stderr.writeLine("[lsp-thread] processing definition request: " & d.str1 & " line=" & $d.int1 & " col=" & $d.int2)
            definitionFuture = definitionAsync(client, d.str1, d.int1, d.int2)
          if running and lastFormat.isSome:
            let f = lastFormat.get()
            if f.range.start.line >= 0:
              stderr.writeLine("[lsp-thread] processing range format request: " & f.str1)
              formatFuture = rangeFormattingAsync(client, f.str1, f.range)
            else:
              stderr.writeLine("[lsp-thread] processing format request: " & f.str1)
              formatFuture = formattingAsync(client, f.str1)
            formatRequestMeta = some(f)
          if running and lastRename.isSome:
            let r = lastRename.get()
            stderr.writeLine("[lsp-thread] processing rename request: " & r.str1 & " line=" & $r.int1 & " col=" & $r.int2)
            renameFuture = renameAsync(client, r.str1, r.int1, r.int2, r.str2)
            renameRequestMeta = some(r)
          if running and lastReferences.isSome:
            let r = lastReferences.get()
            stderr.writeLine("[lsp-thread] processing references request: " & r.str1 & " line=" & $r.int1 & " col=" & $r.int2)
            referencesFuture = referencesAsync(client, r.str1, r.int1, r.int2)
            referencesRequestMeta = some(r)
          if running and lastDocumentSymbols.isSome:
            let d = lastDocumentSymbols.get()
            stderr.writeLine("[lsp-thread] processing document symbols request: " & d.str1)
            documentSymbolsFuture = documentSymbolAsync(client, d.str1)
            documentSymbolsRequestMeta = some(d)
          if running and lastWorkspaceSymbols.isSome:
            let w = lastWorkspaceSymbols.get()
            stderr.writeLine("[lsp-thread] processing workspace symbols request: query=" & w.str1)
            workspaceSymbolsFuture = workspaceSymbolAsync(client, w.str1)
            workspaceSymbolsRequestMeta = some(w)
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

        if formatFuture != nil and formatFuture.finished:
          hadFlushWork = true
          let edits = formatFuture.read()
          let reqMeta = if formatRequestMeta.isSome: formatRequestMeta.get() else: LSPMessage(kind: lmkFormat)
          stderr.writeLine("[lsp-thread] format response ready: edits=" & $edits.len)
          t.sendResponse(LSPMessage(kind: lmkFormat, str1: reqMeta.str1, edits: edits))
          formatFuture = nil
          formatRequestMeta = none(LSPMessage)

        if renameFuture != nil and renameFuture.finished:
          hadFlushWork = true
          let wsEdit = renameFuture.read()
          let reqMeta = if renameRequestMeta.isSome: renameRequestMeta.get() else: LSPMessage(kind: lmkRename)
          stderr.writeLine("[lsp-thread] rename response ready: changes=" & $wsEdit.changes.len)
          t.sendResponse(LSPMessage(kind: lmkRename, str1: reqMeta.str1, workspaceEdit: wsEdit))
          renameFuture = nil
          renameRequestMeta = none(LSPMessage)

        if referencesFuture != nil and referencesFuture.finished:
          hadFlushWork = true
          let locs = referencesFuture.read()
          let reqMeta = if referencesRequestMeta.isSome: referencesRequestMeta.get() else: LSPMessage(kind: lmkReferences)
          stderr.writeLine("[lsp-thread] references response ready: locs=" & $locs.len)
          t.sendResponse(LSPMessage(kind: lmkReferences, str1: reqMeta.str1, locations: locs))
          referencesFuture = nil
          referencesRequestMeta = none(LSPMessage)

        if documentSymbolsFuture != nil and documentSymbolsFuture.finished:
          hadFlushWork = true
          let symbols = documentSymbolsFuture.read()
          let reqMeta = if documentSymbolsRequestMeta.isSome: documentSymbolsRequestMeta.get() else: LSPMessage(kind: lmkDocumentSymbols)
          stderr.writeLine("[lsp-thread] document symbols response ready: symbols=" & $symbols.len)
          t.sendResponse(LSPMessage(kind: lmkDocumentSymbols, str1: reqMeta.str1, symbols: symbols))
          documentSymbolsFuture = nil
          documentSymbolsRequestMeta = none(LSPMessage)

        if workspaceSymbolsFuture != nil and workspaceSymbolsFuture.finished:
          hadFlushWork = true
          let symbols = workspaceSymbolsFuture.read()
          let reqMeta = if workspaceSymbolsRequestMeta.isSome: workspaceSymbolsRequestMeta.get() else: LSPMessage(kind: lmkWorkspaceSymbols)
          stderr.writeLine("[lsp-thread] workspace symbols response ready: symbols=" & $symbols.len)
          t.sendResponse(LSPMessage(kind: lmkWorkspaceSymbols, str1: reqMeta.str1, symbols: symbols))
          workspaceSymbolsFuture = nil
          workspaceSymbolsRequestMeta = none(LSPMessage)

        if diagBuffer.len > 0 or msgBuffer.len > 0:
          hadFlushWork = true
          var diags = diagBuffer
          var msgs = msgBuffer
          diagBuffer = @[]
          msgBuffer = @[]
          for d in diags:
            t.sendResponse(LSPMessage(kind: lmkDiagnostics, jsonData: d))
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

proc newLSPThread*(serverName: string = "minlsp"; language: string = "nim"; initOptions: JsonNode = nil): LSPThread =
  result = LSPThread()
  result.reqChan = newSPSChannel[LSPMessage](64)
  result.respChan = newSPSChannel[LSPMessage](256)
  createThread(result.thread, lspThreadProc, result)
  let opts = if initOptions != nil: initOptions else: newJObject()
  let initMsg = LSPMessage(kind: lmkReady, str1: serverName, str2: language, jsonData: opts)
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

proc requestFormatting*(t: LSPThread; path: string) =
  stderr.writeLine("[lsp-thread] requestFormatting queued: " & path)
  t.queueRequest(LSPMessage(kind: lmkFormat, str1: path))

proc requestRangeFormatting*(t: LSPThread; path: string; range: LSPRange) =
  stderr.writeLine("[lsp-thread] requestRangeFormatting queued: " & path)
  t.queueRequest(LSPMessage(kind: lmkFormat, str1: path, range: range))

proc requestRename*(t: LSPThread; path: string; line, col: int; newName: string) =
  stderr.writeLine("[lsp-thread] requestRename queued: " & path & " line=" & $line & " col=" & $col)
  t.queueRequest(LSPMessage(kind: lmkRename, str1: path, int1: line, int2: col, str2: newName))

proc requestReferences*(t: LSPThread; path: string; line, col: int) =
  stderr.writeLine("[lsp-thread] requestReferences queued: " & path & " line=" & $line & " col=" & $col)
  t.queueRequest(LSPMessage(kind: lmkReferences, str1: path, int1: line, int2: col))

proc requestDocumentSymbols*(t: LSPThread; path: string) =
  stderr.writeLine("[lsp-thread] requestDocumentSymbols queued: " & path)
  t.queueRequest(LSPMessage(kind: lmkDocumentSymbols, str1: path))

proc requestWorkspaceSymbols*(t: LSPThread; query: string) =
  stderr.writeLine("[lsp-thread] requestWorkspaceSymbols queued: query=" & query)
  t.queueRequest(LSPMessage(kind: lmkWorkspaceSymbols, str1: query))

proc notifyDidOpen*(t: LSPThread; path, content: string) =
  t.queueRequest(LSPMessage(kind: lmkDidOpen, str1: path, str2: content))

proc notifyDidChange*(t: LSPThread; path, content: string) =
  t.queueRequest(LSPMessage(kind: lmkDidChange, str1: path, str2: content))

proc notifyDidClose*(t: LSPThread; path: string) =
  t.queueRequest(LSPMessage(kind: lmkDidClose, str1: path))

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

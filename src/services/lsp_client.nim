## Simplified async LSP client for Drift
## Uses chronos + lsp_client's LspNimEndpoint directly

import std/[options, os, json, tables, strutils]
import chronos
import chronos/asyncproc
import lsp_client/nim_lsp_endpoint
import ../core/types

type
  LSPState* = enum
    lspUninitialized
    lspInitializing
    lspReady
    lspError
    lspShutdown

  PublishDiagnosticsCallback* = proc(diagnosticsJson: JsonNode) {.gcsafe.}
  ShowMessageCallback* = proc(message: string, msgType: int) {.gcsafe.}

  PendingRequest = object
    future: Future[JsonNode]
    methodName: string

  LSPClientObj = object
    endpoint: LspNimEndpoint
    state: LSPState
    errorMsg: string
    nextId: int
    pending: Table[int, PendingRequest]
    onDiagnostics: PublishDiagnosticsCallback
    onShowMessage: ShowMessageCallback
    readLoop: Future[void]
    stopRequested: bool
    language: string
    process: AsyncProcessRef
    documentVersions: Table[string, int]
    lastHoverRequestId: int

  LSPClient* = ref LSPClientObj

proc cancelHover*(client: LSPClient) =
  if client.lastHoverRequestId > 0:
    let id = client.lastHoverRequestId
    let cancelParams = %*{ "id": id }
    asyncSpawn client.endpoint.sendNotification("$/cancelRequest", cancelParams)
    if id in client.pending:
      let pending = client.pending[id]
      if not pending.future.finished:
        pending.future.fail(newException(CatchableError, "Cancelled"))
      client.pending.del(id)
    client.lastHoverRequestId = 0

# Client lifecycle

proc startLSP*(language, serverName: string, initOptions: JsonNode = newJObject()): Future[LSPClient] {.async.} =
  stderr.writeLine("[lsp-client] startLSP called: " & serverName)
  var client = LSPClient(
    endpoint: LspNimEndpoint.new(),
    state: lspInitializing,
    nextId: 1,
    language: language,
  )
  client.pending = initTable[int, PendingRequest]()

  let exe = serverName
  if exe.len == 0:
    client.state = lspError
    client.errorMsg = "Unsupported language: " & language
    stderr.writeLine("[lsp-client] error: unsupported language")
    return client

  let exePath = findExe(exe)
  if exePath.len == 0:
    client.state = lspError
    client.errorMsg = "LSP server not found: " & exe
    stderr.writeLine("[lsp-client] error: server not found: " & exe)
    return client

  stderr.writeLine("[lsp-client] starting process: " & exePath)
  try:
    let startFut = asyncproc.startProcess(
      exePath,
      options = {},
      stdoutHandle = AsyncProcess.Pipe,
      stderrHandle = AsyncProcess.Pipe,
      stdinHandle = AsyncProcess.Pipe,
    )
    if not await withTimeout(startFut, 30.seconds):
      client.state = lspError
      client.errorMsg = "LSP server startup timed out"
      stderr.writeLine("[lsp-client] error: process start timed out")
      return client
    let process = startFut.read()
    client.process = process
    client.endpoint.setProcess(process)
    client.documentVersions = initTable[string, int]()
    stderr.writeLine("[lsp-client] process started, sending initialize")
  except CatchableError as e:
    client.state = lspError
    client.errorMsg = "Failed to start LSP: " & e.msg
    stderr.writeLine("[lsp-client] error: process start exception: " & e.msg)
    if client.process != nil:
      try: 
        discard client.process.terminate()
      except CatchableError as te:
        stderr.writeLine("[lsp-client] error: failed to terminate process: " & te.msg)
    return client

  # Initialize
  try:
    let currentDir = getCurrentDir()
    let initParams = %*{
      "processId": getCurrentProcessId(),
      "rootPath": currentDir,
      "rootUri": "file://" & currentDir,
      "initializationOptions": initOptions,
      "capabilities": {
        "textDocument": {
          "synchronization": {},
          "completion": {},
          "hover": {},
          "signatureHelp": {},
          "definition": {},
          "typeDefinition": {},
          "implementation": {},
          "references": {},
          "documentHighlight": {},
          "documentSymbol": {},
          "codeAction": {},
          "codeLens": {},
          "documentLink": {},
          "colorProvider": {},
          "formatting": {},
          "rangeFormatting": {},
          "onTypeFormatting": {},
          "rename": {},
          "publishDiagnostics": {},
          "foldingRange": {},
          "selectionRange": {}
        },
        "workspace": {
          "applyEdit": true,
          "workspaceEdit": {},
          "didChangeConfiguration": {},
          "didChangeWatchedFiles": {},
          "symbol": {},
          "executeCommand": {},
          "workspaceFolders": true,
          "configuration": true
        },
        "window": {},
        "experimental": {}
      },
      "trace": "off",
      "workspaceFolders": nil
    }
    let initReq = %*{ "jsonrpc": "2.0", "id": 0, "method": "initialize", "params": initParams }
    await client.endpoint.send($initReq)
    stderr.writeLine("[lsp-client] initialize sent, waiting for response")
    let readFut = client.endpoint.readMessage()
    if not await withTimeout(readFut, 30.seconds):
      client.state = lspError
      client.errorMsg = "LSP initialize timed out"
      stderr.writeLine("[lsp-client] error: initialize timed out")
      if client.process != nil:
        try: 
          discard client.process.terminate()
        except CatchableError as te:
          stderr.writeLine("[lsp-client] error: failed to terminate process: " & te.msg)
      return client
    let initRespStr = readFut.read()
    stderr.writeLine("[lsp-client] initialize response received")
    let initResp = parseJson(initRespStr)
    if initResp.hasKey("error"):
      client.state = lspError
      client.errorMsg = $initResp["error"]["message"]
      stderr.writeLine("[lsp-client] error: initialize returned error: " & client.errorMsg)
      if client.process != nil:
        try: 
          discard client.process.terminate()
        except CatchableError as te:
          stderr.writeLine("[lsp-client] error: failed to terminate process: " & te.msg)
      return client

    # Send initialized notification
    let initializedNotif = %*{ "jsonrpc": "2.0", "method": "initialized", "params": {} }
    await client.endpoint.send($initializedNotif)
    client.state = lspReady
    stderr.writeLine("[lsp-client] initialized, ready")
  except CatchableError as e:
    client.state = lspError
    client.errorMsg = "LSP init failed: " & e.msg
    stderr.writeLine("[lsp-client] error: init exception: " & e.msg)
    if client.process != nil:
      try: 
        discard client.process.terminate()
      except CatchableError as te:
        stderr.writeLine("[lsp-client] error: failed to terminate process: " & te.msg)

  return client
# Message reading loop (notifications + response routing)

proc readLoop(client: LSPClient) {.async: (raises: [Exception]).} =
  var consecutiveErrors = 0
  const MaxConsecutiveErrors = 20
  while not client.stopRequested and client.state != lspShutdown:
    try:
      let msgStr = await client.endpoint.readMessage()
      consecutiveErrors = 0
      let msg = parseJson(msgStr)

      # Response to pending request
      if msg.hasKey("id") and msg["id"].kind != JNull:
        let id = msg["id"].getInt()
        if id in client.pending:
          let pending = client.pending[id]
          if not pending.future.finished:
            pending.future.complete(msg)
          client.pending.del(id)
        continue

      # Notification
      if msg.hasKey("method"):
        let methodName = msg["method"].getStr()
        if methodName == "textDocument/publishDiagnostics" and client.onDiagnostics != nil:
          try:
            client.onDiagnostics(msg)
          except CatchableError as e:
            stderr.writeLine("[lsp-client] error: diagnostics callback failed: " & e.msg)
        elif methodName == "window/showMessage" and client.onShowMessage != nil:
          try:
            let msgText = msg["params"]["message"].getStr()
            let msgType = msg["params"]["type"].getInt()
            client.onShowMessage(msgText, msgType)
          except CatchableError as e:
            stderr.writeLine("[lsp-client] error: showMessage callback failed: " & e.msg)
    except CatchableError as e:
      inc consecutiveErrors
      stderr.writeLine("[lsp-client] error: readLoop exception: " & e.msg & " (consecutive: " & $consecutiveErrors & ")")
      if consecutiveErrors >= MaxConsecutiveErrors:
        client.state = lspError
        client.errorMsg = "LSP server disconnected"
        break
      await sleepAsync(50.milliseconds)

proc ensureReadLoop*(client: LSPClient) =
  if client.readLoop.isNil or client.readLoop.finished or client.readLoop.failed:
    client.readLoop = readLoop(client)
    asyncSpawn client.readLoop

proc stopLSP*(client: LSPClient) {.async.} =
  client.stopRequested = true
  # Fail any outstanding requests so awaiters don't hang
  for id, pending in client.pending:
    if not pending.future.finished:
      pending.future.fail(newException(CatchableError, "LSP shutting down"))
  client.pending.clear()
  client.lastHoverRequestId = 0
  try:
    let shutdownReq = %*{ "jsonrpc": "2.0", "id": 9999, "method": "shutdown" }
    await client.endpoint.send($shutdownReq)
    let exitNotif = %*{ "jsonrpc": "2.0", "method": "exit" }
    await client.endpoint.send($exitNotif)
  except CatchableError as e:
    stderr.writeLine("[lsp-client] error: shutdown failed: " & e.msg)
  client.state = lspShutdown
  if not client.readLoop.isNil and not client.readLoop.finished:
    try:
      if not await withTimeout(client.readLoop, 5.seconds):
        stderr.writeLine("[lsp-client] warning: readLoop shutdown timed out")
    except CatchableError as e:
      stderr.writeLine("[lsp-client] error: readLoop shutdown exception: " & e.msg)
  if client.process != nil:
    try:
      discard client.process.terminate()
    except CatchableError as e:
      stderr.writeLine("[lsp-client] error: process termination failed: " & e.msg)

# Helpers

proc toFileUri*(path: string): string =
  var p = path.replace('\\', '/')
  p = p.replace(" ", "%20")
  when defined(windows):
    if p.len > 0 and p[1] == ':':
      p = "/" & p
    result = "file://" & p
  else:
    result = "file://" & p

proc isReady*(client: LSPClient): bool =
  client != nil and client.state == lspReady

proc errorMsg*(client: LSPClient): string =
  if client != nil: client.errorMsg else: ""

proc setDiagnosticsCallback*(client: LSPClient; cb: PublishDiagnosticsCallback) =
  client.onDiagnostics = cb

proc setShowMessageCallback*(client: LSPClient; cb: ShowMessageCallback) =
  client.onShowMessage = cb

proc beginRequest(client: LSPClient; methodName: string; params: JsonNode): tuple[id: int, future: Future[JsonNode]] =
  let id = client.nextId
  inc client.nextId
  let req = %*{ "jsonrpc": "2.0", "id": id, "method": methodName, "params": params }
  result.future = newFuture[JsonNode]("lsp_request")
  client.pending[id] = PendingRequest(future: result.future, methodName: methodName)
  result.id = id
  asyncSpawn client.endpoint.send($req)

proc sendRequest(client: LSPClient; methodName: string; params: JsonNode): Future[JsonNode] {.async.} =
  let (id, fut) = beginRequest(client, methodName, params)
  if await withTimeout(fut, 30.seconds):
    result = fut.read()
  else:
    if id in client.pending:
      client.pending.del(id)
    raise newException(CatchableError, "LSP request timed out: " & methodName)

proc sendNotification(client: LSPClient; methodName: string; params: JsonNode) {.async.} =
  let notif = %*{ "jsonrpc": "2.0", "method": methodName, "params": params }
  await client.endpoint.send($notif)

# Document sync

proc didOpen*(client: LSPClient; path, content: string) {.async.} =
  if not client.isReady: return
  let uri = toFileUri(path)
  client.documentVersions[uri] = 1
  let params = %*{
    "textDocument": {
      "uri": uri,
      "languageId": client.language,
      "version": 1,
      "text": content
    }
  }
  await client.sendNotification("textDocument/didOpen", params)

proc didChange*(client: LSPClient; path, content: string) {.async.} =
  if not client.isReady: return
  let uri = toFileUri(path)
  var version = 2
  if client.documentVersions.hasKey(uri):
    version = client.documentVersions[uri] + 1
  client.documentVersions[uri] = version
  let params = %*{
    "textDocument": {
      "uri": uri,
      "version": version
    },
    "contentChanges": [
      { "text": content }
    ]
  }
  await client.sendNotification("textDocument/didChange", params)

# Hover

proc hoverAsync*(client: LSPClient; path: string; line, col: int): Future[Option[string]] {.async.} =
  if not client.isReady:
    stderr.writeLine("[lsp-client] hoverAsync skipped: client not ready")
    return none(string)
  # Cancel any previous hover so it doesn't shadow this one
  if client.lastHoverRequestId > 0:
    cancelHover(client)
  let uri = toFileUri(path)
  let params = %*{
    "textDocument": { "uri": uri },
    "position": { "line": line, "character": col }
  }
  stderr.writeLine("[lsp-client] hoverAsync sending request: " & path & " line=" & $line & " col=" & $col)
  try:
    let (id, fut) = beginRequest(client, "textDocument/hover", params)
    client.lastHoverRequestId = id
    if await withTimeout(fut, 30.seconds):
      let resp = fut.read()
      client.lastHoverRequestId = 0
      stderr.writeLine("[lsp-client] hoverAsync response received: hasResult=" & $resp.hasKey("result"))
      if resp.hasKey("result") and resp["result"].kind != JNull:
        let resultData = resp["result"]
        if resultData.kind == JObject and resultData.hasKey("contents"):
          let contents = resultData["contents"]
          if contents.kind == JArray and contents.len > 0:
            var text = ""
            for item in contents:
              if text.len > 0: text.add "\n\n"
              if item.kind == JObject:
                if item.hasKey("value"):
                  text.add item["value"].getStr()
                elif item.hasKey("kind") and item.hasKey("value"):
                  text.add item["value"].getStr()
              elif item.kind == JString:
                text.add item.getStr()
            if text.len > 0:
              stderr.writeLine("[lsp-client] hoverAsync parsed array text length=" & $text.len)
              return some(text)
          elif contents.kind == JObject:
            if contents.hasKey("value"):
              let text = contents["value"].getStr()
              stderr.writeLine("[lsp-client] hoverAsync parsed object text length=" & $text.len)
              return some(text)
          elif contents.kind == JString:
            let text = contents.getStr()
            stderr.writeLine("[lsp-client] hoverAsync parsed string text length=" & $text.len)
            return some(text)
      stderr.writeLine("[lsp-client] hoverAsync returning none (empty or null result)")
      return none(string)
    else:
      if id in client.pending:
        client.pending.del(id)
      client.lastHoverRequestId = 0
      stderr.writeLine("[lsp-client] hoverAsync timed out")
      return none(string)
  except CatchableError as e:
    client.lastHoverRequestId = 0
    stderr.writeLine("[lsp-client] hoverAsync exception: " & e.msg)
    return none(string)

# Definition

proc definitionAsync*(client: LSPClient; path: string; line, col: int): Future[seq[Location]] {.async.} =
  result = @[]
  if not client.isReady:
    return
  let uri = toFileUri(path)
  let params = %*{
    "textDocument": { "uri": uri },
    "position": { "line": line, "character": col }
  }
  try:
    let resp = await client.sendRequest("textDocument/definition", params)
    stderr.writeLine("[lsp-client] definitionAsync response received: hasResult=" & $resp.hasKey("result") & " resultKind=" & $(if resp.hasKey("result"): $resp["result"].kind else: "n/a"))
    if resp.hasKey("result") and resp["result"].kind != JNull:
      let resultData = resp["result"]
      if resultData.kind == JArray:
        stderr.writeLine("[lsp-client] definitionAsync result is array, len=" & $resultData.len)
        for item in resultData:
          if item.hasKey("uri") and item.hasKey("range"):
            let range = item["range"]
            result.add(Location(
              uri: item["uri"].getStr(),
              range: LSPRange(
                start: LSPPosition(
                  line: range["start"]["line"].getInt(),
                  character: range["start"]["character"].getInt()
                ),
                `end`: LSPPosition(
                  line: range["end"]["line"].getInt(),
                  character: range["end"]["character"].getInt()
                )
              )
            ))
      elif resultData.hasKey("uri") and resultData.hasKey("range"):
        stderr.writeLine("[lsp-client] definitionAsync result is single object")
        let range = resultData["range"]
        result.add(Location(
          uri: resultData["uri"].getStr(),
          range: LSPRange(
            start: LSPPosition(
              line: range["start"]["line"].getInt(),
              character: range["start"]["character"].getInt()
            ),
            `end`: LSPPosition(
              line: range["end"]["line"].getInt(),
              character: range["end"]["character"].getInt()
            )
          )
        ))
      else:
        stderr.writeLine("[lsp-client] definitionAsync result has unexpected shape: " & $resultData)
    else:
      stderr.writeLine("[lsp-client] definitionAsync result is null or missing")
  except CatchableError as e:
    stderr.writeLine("[lsp-client] definitionAsync exception: " & e.msg)

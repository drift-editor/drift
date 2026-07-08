## Simplified async LSP client for Drift
## Uses chronos + lsp_client's LspNimEndpoint directly

import std/[options, os, json, tables, strutils, algorithm]
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

  LSPTextEdit* = object
    range*: LSPRange
    newText*: string

  LSPWorkspaceEdit* = object
    changes*: Table[string, seq[LSPTextEdit]]

  LSPSymbol* = object
    name*: string
    kind*: int
    uri*: string
    range*: LSPRange

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
      let errObj = initResp["error"]
      client.errorMsg = if errObj.hasKey("message"): errObj["message"].getStr() else: "unknown initialize error"
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
  if client.readLoop == nil or client.readLoop.finished or client.readLoop.failed:
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
  if client.readLoop != nil and not client.readLoop.finished:
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
  ## Percent-encode path characters per RFC 3986 unreserved set.
  ## Unreserved: A-Z a-z 0-9 - _ . ~ / (and : for Windows drive letters).
  var p = path.replace('\\', '/')
  var encoded = ""
  for c in p:
    case c
    of 'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~', '/':
      encoded.add(c)
    of ':':
      # Keep colons for Windows drive letters (C:/...) but encode elsewhere
      when defined(windows):
        if encoded.len == 1 and p[0] in {'A'..'Z', 'a'..'z'}:
          encoded.add(c)
        else:
          encoded.add('%' & toHex(ord(c), 2).toUpperAscii())
      else:
        encoded.add('%' & toHex(ord(c), 2).toUpperAscii())
    else:
      encoded.add('%' & toHex(ord(c), 2).toUpperAscii())
  when defined(windows):
    if encoded.len >= 2 and encoded[1] == ':':
      result = "file:///" & encoded
    else:
      result = "file://" & encoded
  else:
    result = "file://" & encoded

proc decodeFileUri*(uri: string): string =
  ## Strip file:// prefix and decode percent-encoded characters.
  if uri.startsWith("file://"):
    result = uri[7..^1]
    when defined(windows):
      ## On Windows toFileUri emits file:///C:/path (three slashes).
      ## Stripping file:// leaves /C:/path which is invalid — remove the
      ## leading slash so the drive letter is at the start.
      if result.len > 0 and result[0] == '/':
        result = result[1..^1]
  else:
    result = uri
  # Decode common percent-encoded characters
  result = result.replace("%20", " ")
  result = result.replace("%23", "#")
  result = result.replace("%25", "%")
  result = result.replace("%3F", "?")

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

proc didClose*(client: LSPClient; path: string) {.async.} =
  if not client.isReady: return
  let uri = toFileUri(path)
  client.documentVersions.del(uri)
  let params = %*{
    "textDocument": { "uri": uri }
  }
  await client.sendNotification("textDocument/didClose", params)

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

# Formatting

proc formattingAsync*(client: LSPClient; path: string): Future[seq[LSPTextEdit]] {.async.} =
  ## Request `textDocument/formatting` for the given file path.
  ## Returns a sequence of LSP text edits to apply, or empty if none.
  result = @[]
  if not client.isReady:
    return
  let uri = toFileUri(path)
  let params = %*{
    "textDocument": { "uri": uri },
    "options": { "tabSize": 2, "insertSpaces": true }
  }
  try:
    let resp = await client.sendRequest("textDocument/formatting", params)
    if resp.hasKey("result") and resp["result"].kind == JArray:
      for item in resp["result"]:
        if item.hasKey("range") and item.hasKey("newText"):
          let range = item["range"]
          let newText = item["newText"].getStr()
          result.add(LSPTextEdit(
            range: LSPRange(
              start: LSPPosition(
                line: range["start"]["line"].getInt(),
                character: range["start"]["character"].getInt()
              ),
              `end`: LSPPosition(
                line: range["end"]["line"].getInt(),
                character: range["end"]["character"].getInt()
              )
            ),
            newText: newText
          ))
  except CatchableError as e:
    stderr.writeLine("[lsp-client] formattingAsync exception: " & e.msg)

proc rangeFormattingAsync*(client: LSPClient; path: string; range: LSPRange): Future[seq[LSPTextEdit]] {.async.} =
  ## Request `textDocument/rangeFormatting` for the given file path and range.
  ## Returns a sequence of LSP text edits to apply, or empty if none.
  result = @[]
  if not client.isReady:
    return
  let uri = toFileUri(path)
  let params = %*{
    "textDocument": { "uri": uri },
    "range": {
      "start": { "line": range.start.line, "character": range.start.character },
      "end": { "line": range.end.line, "character": range.end.character }
    },
    "options": { "tabSize": 2, "insertSpaces": true }
  }
  try:
    let resp = await client.sendRequest("textDocument/rangeFormatting", params)
    if resp.hasKey("result") and resp["result"].kind == JArray:
      for item in resp["result"]:
        if item.hasKey("range") and item.hasKey("newText"):
          let itemRange = item["range"]
          let newText = item["newText"].getStr()
          result.add(LSPTextEdit(
            range: LSPRange(
              start: LSPPosition(
                line: itemRange["start"]["line"].getInt(),
                character: itemRange["start"]["character"].getInt()
              ),
              `end`: LSPPosition(
                line: itemRange["end"]["line"].getInt(),
                character: itemRange["end"]["character"].getInt()
              )
            ),
            newText: newText
          ))
  except CatchableError as e:
    stderr.writeLine("[lsp-client] rangeFormattingAsync exception: " & e.msg)

# Rename

proc renameAsync*(client: LSPClient; path: string; line, col: int; newName: string): Future[LSPWorkspaceEdit] {.async.} =
  ## Request `textDocument/rename` for the symbol at the given position.
  ## Returns a workspace edit with document changes to apply.
  result.changes = initTable[string, seq[LSPTextEdit]]()
  if not client.isReady:
    return
  let uri = toFileUri(path)
  let params = %*{
    "textDocument": { "uri": uri },
    "position": { "line": line, "character": col },
    "newName": newName
  }
  try:
    let resp = await client.sendRequest("textDocument/rename", params)
    if resp.hasKey("result") and resp["result"].kind == JObject:
      let resultData = resp["result"]
      if resultData.hasKey("changes") and resultData["changes"].kind == JObject:
        for uriKey, editsNode in resultData["changes"]:
          var edits: seq[LSPTextEdit] = @[]
          if editsNode.kind == JArray:
            for item in editsNode:
              if item.hasKey("range") and item.hasKey("newText"):
                let range = item["range"]
                edits.add(LSPTextEdit(
                  range: LSPRange(
                    start: LSPPosition(
                      line: range["start"]["line"].getInt(),
                      character: range["start"]["character"].getInt()
                    ),
                    `end`: LSPPosition(
                      line: range["end"]["line"].getInt(),
                      character: range["end"]["character"].getInt()
                    )
                  ),
                  newText: item["newText"].getStr()
                ))
          if edits.len > 0:
            result.changes[uriKey] = edits
  except CatchableError as e:
    stderr.writeLine("[lsp-client] renameAsync exception: " & e.msg)

# References

proc referencesAsync*(client: LSPClient; path: string; line, col: int): Future[seq[Location]] {.async.} =
  ## Request `textDocument/references` for the symbol at the given position.
  result = @[]
  if not client.isReady:
    return
  let uri = toFileUri(path)
  let params = %*{
    "textDocument": { "uri": uri },
    "position": { "line": line, "character": col },
    "context": { "includeDeclaration": true }
  }
  try:
    let resp = await client.sendRequest("textDocument/references", params)
    if resp.hasKey("result") and resp["result"].kind == JArray:
      for item in resp["result"]:
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
  except CatchableError as e:
    stderr.writeLine("[lsp-client] referencesAsync exception: " & e.msg)

proc parseSymbolRange(item: JsonNode): LSPRange =
  let rangeNode = if item.hasKey("range"): item["range"] elif item.hasKey("location") and item["location"].hasKey("range"): item["location"]["range"] else: newJObject()
  if rangeNode.hasKey("start") and rangeNode.hasKey("end"):
    result.start = LSPPosition(
      line: rangeNode["start"]["line"].getInt(),
      character: rangeNode["start"]["character"].getInt()
    )
    result.`end` = LSPPosition(
      line: rangeNode["end"]["line"].getInt(),
      character: rangeNode["end"]["character"].getInt()
    )

proc documentSymbolAsync*(client: LSPClient; path: string): Future[seq[LSPSymbol]] {.async.} =
  ## Request `textDocument/documentSymbol` for the given file path.
  result = @[]
  if not client.isReady:
    return
  let uri = toFileUri(path)
  let params = %*{ "textDocument": { "uri": uri } }
  try:
    let resp = await client.sendRequest("textDocument/documentSymbol", params)
    if resp.hasKey("result") and resp["result"].kind == JArray:
      for item in resp["result"]:
        if item.hasKey("name"):
          result.add(LSPSymbol(
            name: item["name"].getStr(),
            kind: if item.hasKey("kind"): item["kind"].getInt() else: 0,
            uri: uri,
            range: parseSymbolRange(item)
          ))
  except CatchableError as e:
    stderr.writeLine("[lsp-client] documentSymbolAsync exception: " & e.msg)

proc workspaceSymbolAsync*(client: LSPClient; query: string): Future[seq[LSPSymbol]] {.async.} =
  ## Request `workspace/symbol` with the given query string.
  result = @[]
  if not client.isReady:
    return
  let params = %*{ "query": query }
  try:
    let resp = await client.sendRequest("workspace/symbol", params)
    if resp.hasKey("result") and resp["result"].kind == JArray:
      for item in resp["result"]:
        if item.hasKey("name"):
          let uri = if item.hasKey("location") and item["location"].hasKey("uri"): item["location"]["uri"].getStr() else: ""
          result.add(LSPSymbol(
            name: item["name"].getStr(),
            kind: if item.hasKey("kind"): item["kind"].getInt() else: 0,
            uri: uri,
            range: parseSymbolRange(item)
          ))
  except CatchableError as e:
    stderr.writeLine("[lsp-client] workspaceSymbolAsync exception: " & e.msg)

# Apply workspace edit helper

proc offsetAtLineCol*(text: string; line, col: int): int =
  ## Convert 0-based line/col to byte offset in text using LF line endings.
  var curLine = 0
  var curCol = 0
  while result < text.len:
    if curLine == line and curCol == col:
      break
    if text[result] == '\L':
      inc curLine
      curCol = 0
    else:
      inc curCol
    inc result

proc applyTextEdits*(fullText: string; edits: seq[LSPTextEdit]): string =
  ## Apply LSP text edits to a full document string in reverse order.
  result = fullText
  var sorted = edits
  sorted.sort(proc(a, b: LSPTextEdit): int =
    let lineCmp = cmp(b.range.start.line, a.range.start.line)
    if lineCmp != 0: return lineCmp
    cmp(b.range.start.character, a.range.start.character))
  for ed in sorted:
    let startOffset = offsetAtLineCol(result, ed.range.start.line, ed.range.start.character)
    let endOffset = offsetAtLineCol(result, ed.range.end.line, ed.range.end.character)
    result = result[0 ..< startOffset] & ed.newText & result[endOffset ..< result.len]

proc lineColAtOffset*(text: string; offset: int): tuple[line, col: int] =
  var pos = 0
  result.line = 0
  result.col = 0
  while pos < offset and pos < text.len:
    if text[pos] == '\L':
      inc result.line
      result.col = 0
    else:
      inc result.col
    inc pos

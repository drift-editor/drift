## Simplified async DAP client for Drift
## Uses chronos + lsp_client's LspNimEndpoint for JSON-RPC transport

import std/[os, json, tables]
import chronos
import chronos/asyncproc
import lsp_client/nim_lsp_endpoint

type
  DAPState* = enum
    dapUninitialized
    dapInitializing
    dapReady
    dapRunning
    dapStopped
    dapError
    dapShutdown

  StoppedCallback* = proc(reason: string; threadId: int; description: string) {.gcsafe.}
  OutputCallback* = proc(category: string; output: string) {.gcsafe.}
  TerminatedCallback* = proc() {.gcsafe.}

  PendingDAPRequest = object
    future: Future[JsonNode]
    methodName: string

  DAPClientObj = object
    endpoint: LspNimEndpoint
    state: DAPState
    errorMsg: string
    nextId: int
    pending: Table[int, PendingDAPRequest]
    onStopped: StoppedCallback
    onOutput: OutputCallback
    onTerminated: TerminatedCallback
    readLoop: Future[void]
    stopRequested: bool
    process: AsyncProcessRef

  DAPClient* = ref DAPClientObj

# Client lifecycle

proc startDAP*(adapterName: string): Future[DAPClient] {.async.} =
  stderr.writeLine("[dap-client] startDAP called: " & adapterName)
  var client = DAPClient(
    endpoint: LspNimEndpoint.new(),
    state: dapInitializing,
    nextId: 1,
  )
  client.pending = initTable[int, PendingDAPRequest]()

  let exe = adapterName
  if exe.len == 0:
    client.state = dapError
    client.errorMsg = "DAP adapter name is empty"
    stderr.writeLine("[dap-client] error: empty adapter name")
    return client

  let exePath = findExe(exe)
  if exePath.len == 0:
    client.state = dapError
    client.errorMsg = "DAP adapter not found: " & exe
    stderr.writeLine("[dap-client] error: adapter not found: " & exe)
    return client

  stderr.writeLine("[dap-client] starting process: " & exePath)
  try:
    let startFut = asyncproc.startProcess(
      exePath,
      arguments = @["--stdio"],
      options = {},
      stdoutHandle = AsyncProcess.Pipe,
      stderrHandle = AsyncProcess.Pipe,
      stdinHandle = AsyncProcess.Pipe,
    )
    if not await withTimeout(startFut, 30.seconds):
      client.state = dapError
      client.errorMsg = "DAP adapter startup timed out"
      stderr.writeLine("[dap-client] error: process start timed out")
      return client
    let process = startFut.read()
    client.process = process
    client.endpoint.setProcess(process)
    stderr.writeLine("[dap-client] process started")
  except CatchableError as e:
    client.state = dapError
    client.errorMsg = "Failed to start DAP adapter: " & e.msg
    stderr.writeLine("[dap-client] error: process start exception: " & e.msg)
    return client

  # Send initialize request
  try:
    let initParams = %*{
      "clientID": "drift",
      "clientName": "Drift Editor",
      "adapterID": "nim",
      "pathFormat": "path",
      "linesStartAt1": true,
      "columnsStartAt1": true,
      "supportsVariableType": true,
      "supportsVariablePaging": false,
      "supportsRunInTerminalRequest": false,
      "locale": "en_US"
    }
    let initReq = %*{ "seq": client.nextId, "type": "request", "command": "initialize", "arguments": initParams }
    inc client.nextId
    await client.endpoint.send($initReq)
    stderr.writeLine("[dap-client] initialize sent, waiting for response")
    let readFut = client.endpoint.readMessage()
    if not await withTimeout(readFut, 30.seconds):
      client.state = dapError
      client.errorMsg = "DAP initialize timed out"
      stderr.writeLine("[dap-client] error: initialize timed out")
      if client.process != nil:
        try: discard client.process.terminate()
        except CatchableError: discard
      return client
    let initRespStr = readFut.read()
    stderr.writeLine("[dap-client] initialize response received")
    let initResp = parseJson(initRespStr)
    if initResp.hasKey("success") and not initResp["success"].getBool():
      let msg = if initResp.hasKey("message"): initResp["message"].getStr() else: "unknown"
      client.state = dapError
      client.errorMsg = "DAP initialize failed: " & msg
      stderr.writeLine("[dap-client] error: initialize failed: " & msg)
      if client.process != nil:
        try: discard client.process.terminate()
        except CatchableError: discard
      return client
    client.state = dapReady
    stderr.writeLine("[dap-client] initialized, ready")
  except CatchableError as e:
    client.state = dapError
    client.errorMsg = "DAP init failed: " & e.msg
    stderr.writeLine("[dap-client] error: init exception: " & e.msg)
    if client.process != nil:
      try: discard client.process.terminate()
      except CatchableError: discard

  return client

# Event reading loop

proc readLoop(client: DAPClient) {.async: (raises: [Exception]).} =
  var consecutiveErrors = 0
  const MaxConsecutiveErrors = 20
  while not client.stopRequested and client.state != dapShutdown:
    try:
      let msgStr = await client.endpoint.readMessage()
      consecutiveErrors = 0
      let msg = parseJson(msgStr)

      # Response to pending request
      if msg.hasKey("request_seq"):
        let id = msg["request_seq"].getInt()
        if id in client.pending:
          let pending = client.pending[id]
          if not pending.future.finished:
            pending.future.complete(msg)
          client.pending.del(id)
        continue

      # Event
      if msg.hasKey("type") and msg["type"].getStr() == "event" and msg.hasKey("event"):
        let eventName = msg["event"].getStr()
        let body = if msg.hasKey("body"): msg["body"] else: newJObject()
        case eventName
        of "initialized":
          stderr.writeLine("[dap-client] event: initialized")
        of "stopped":
          client.state = dapStopped
          let reason = if body.hasKey("reason"): body["reason"].getStr() else: ""
          let threadId = if body.hasKey("threadId"): body["threadId"].getInt() else: 0
          let description = if body.hasKey("description"): body["description"].getStr() else: ""
          stderr.writeLine("[dap-client] event: stopped reason=" & reason & " threadId=" & $threadId)
          if client.onStopped != nil:
            try: client.onStopped(reason, threadId, description)
            except CatchableError as e:
              stderr.writeLine("[dap-client] error: stopped callback failed: " & e.msg)
        of "continued":
          client.state = dapRunning
          stderr.writeLine("[dap-client] event: continued")
        of "output":
          let category = if body.hasKey("category"): body["category"].getStr() else: "console"
          let output = if body.hasKey("output"): body["output"].getStr() else: ""
          if client.onOutput != nil:
            try: client.onOutput(category, output)
            except CatchableError as e:
              stderr.writeLine("[dap-client] error: output callback failed: " & e.msg)
        of "terminated":
          stderr.writeLine("[dap-client] event: terminated")
          client.state = dapReady
          if client.onTerminated != nil:
            try: client.onTerminated()
            except CatchableError as e:
              stderr.writeLine("[dap-client] error: terminated callback failed: " & e.msg)
        of "exited":
          let exitCode = if body.hasKey("exitCode"): body["exitCode"].getInt() else: 0
          stderr.writeLine("[dap-client] event: exited code=" & $exitCode)
          client.state = dapReady
        else:
          stderr.writeLine("[dap-client] event: " & eventName)
    except CatchableError as e:
      inc consecutiveErrors
      stderr.writeLine("[dap-client] error: readLoop exception: " & e.msg & " (consecutive: " & $consecutiveErrors & ")")
      if consecutiveErrors >= MaxConsecutiveErrors:
        client.state = dapError
        client.errorMsg = "DAP adapter disconnected"
        break
      await sleepAsync(50.milliseconds)

proc ensureReadLoop*(client: DAPClient) =
  if client.readLoop == nil or client.readLoop.finished or client.readLoop.failed:
    client.readLoop = readLoop(client)
    asyncSpawn client.readLoop

proc stopDAP*(client: DAPClient) {.async.} =
  client.stopRequested = true
  for id, pending in client.pending:
    if not pending.future.finished:
      pending.future.fail(newException(CatchableError, "DAP shutting down"))
  client.pending.clear()
  try:
    let disconnectReq = %*{ "seq": client.nextId, "type": "request", "command": "disconnect", "arguments": {} }
    inc client.nextId
    await client.endpoint.send($disconnectReq)
  except CatchableError as e:
    stderr.writeLine("[dap-client] error: disconnect failed: " & e.msg)
  client.state = dapShutdown
  if client.readLoop != nil and not client.readLoop.finished:
    try:
      if not await withTimeout(client.readLoop, 5.seconds):
        stderr.writeLine("[dap-client] warning: readLoop shutdown timed out")
    except CatchableError as e:
      stderr.writeLine("[dap-client] error: readLoop shutdown exception: " & e.msg)
  if client.process != nil:
    try:
      discard client.process.terminate()
    except CatchableError as e:
      stderr.writeLine("[dap-client] error: process termination failed: " & e.msg)

# Helpers

proc isReady*(client: DAPClient): bool =
  client != nil and (client.state == dapReady or client.state == dapRunning or client.state == dapStopped)

proc isRunning*(client: DAPClient): bool =
  client != nil and client.state == dapRunning

proc isStopped*(client: DAPClient): bool =
  client != nil and client.state == dapStopped

proc errorMsg*(client: DAPClient): string =
  if client != nil: client.errorMsg else: ""

proc setStoppedCallback*(client: DAPClient; cb: StoppedCallback) =
  client.onStopped = cb

proc setOutputCallback*(client: DAPClient; cb: OutputCallback) =
  client.onOutput = cb

proc setTerminatedCallback*(client: DAPClient; cb: TerminatedCallback) =
  client.onTerminated = cb

proc beginRequest(client: DAPClient; command: string; arguments: JsonNode): tuple[id: int, future: Future[JsonNode]] =
  let id = client.nextId
  inc client.nextId
  let req = %*{ "seq": id, "type": "request", "command": command, "arguments": arguments }
  result.future = newFuture[JsonNode]("dap_request")
  client.pending[id] = PendingDAPRequest(future: result.future, methodName: command)
  result.id = id
  asyncSpawn client.endpoint.send($req)

proc sendRequest(client: DAPClient; command: string; arguments: JsonNode): Future[JsonNode] {.async.} =
  let (id, fut) = beginRequest(client, command, arguments)
  if await withTimeout(fut, 30.seconds):
    result = fut.read()
  else:
    if id in client.pending:
      client.pending.del(id)
    raise newException(CatchableError, "DAP request timed out: " & command)

# DAP Requests

proc requestLaunch*(client: DAPClient; program: string; args: seq[string] = @[]; cwd: string = ""; stopOnEntry: bool = false) {.async.} =
  if not client.isReady: return
  let launchArgs = %*{
    "program": program,
    "args": args,
    "cwd": cwd,
    "stopOnEntry": stopOnEntry
  }
  discard await client.sendRequest("launch", launchArgs)
  client.state = dapRunning
  stderr.writeLine("[dap-client] launch sent, state=running")

proc requestAttach*(client: DAPClient; processId: int) {.async.} =
  if not client.isReady: return
  let attachArgs = %*{ "processId": processId }
  discard await client.sendRequest("attach", attachArgs)
  client.state = dapRunning

proc requestSetBreakpoints*(client: DAPClient; path: string; lines: seq[int]): Future[seq[tuple[line: int; verified: bool]]] {.async.} =
  result = @[]
  if not client.isReady: return
  var breakpoints = newJArray()
  for line in lines:
    breakpoints.add(%*{ "line": line })
  let args = %*{
    "source": { "path": path },
    "breakpoints": breakpoints
  }
  let resp = await client.sendRequest("setBreakpoints", args)
  if resp.hasKey("body") and resp["body"].hasKey("breakpoints"):
    let arr = resp["body"]["breakpoints"]
    for item in arr:
      let line = if item.hasKey("line"): item["line"].getInt() else: 0
      let verified = if item.hasKey("verified"): item["verified"].getBool() else: false
      result.add((line, verified))

proc requestConfigurationDone*(client: DAPClient) {.async.} =
  if not client.isReady: return
  discard await client.sendRequest("configurationDone", newJObject())

proc requestStackTrace*(client: DAPClient; threadId: int): Future[JsonNode] {.async.} =
  if not client.isReady:
    return newJObject()
  let args = %*{ "threadId": threadId }
  result = await client.sendRequest("stackTrace", args)

proc requestScopes*(client: DAPClient; frameId: int): Future[JsonNode] {.async.} =
  if not client.isReady:
    return newJObject()
  let args = %*{ "frameId": frameId }
  result = await client.sendRequest("scopes", args)

proc requestVariables*(client: DAPClient; variablesReference: int): Future[JsonNode] {.async.} =
  if not client.isReady:
    return newJObject()
  let args = %*{ "variablesReference": variablesReference }
  result = await client.sendRequest("variables", args)

proc requestContinue*(client: DAPClient; threadId: int) {.async.} =
  if not client.isReady: return
  let args = %*{ "threadId": threadId }
  discard await client.sendRequest("continue", args)
  client.state = dapRunning

proc requestNext*(client: DAPClient; threadId: int) {.async.} =
  if not client.isReady: return
  let args = %*{ "threadId": threadId }
  discard await client.sendRequest("next", args)
  client.state = dapRunning

proc requestStepIn*(client: DAPClient; threadId: int) {.async.} =
  if not client.isReady: return
  let args = %*{ "threadId": threadId }
  discard await client.sendRequest("stepIn", args)
  client.state = dapRunning

proc requestStepOut*(client: DAPClient; threadId: int) {.async.} =
  if not client.isReady: return
  let args = %*{ "threadId": threadId }
  discard await client.sendRequest("stepOut", args)
  client.state = dapRunning

proc requestPause*(client: DAPClient; threadId: int) {.async.} =
  if not client.isReady: return
  let args = %*{ "threadId": threadId }
  discard await client.sendRequest("pause", args)

proc requestDisconnect*(client: DAPClient) {.async.} =
  if not client.isReady: return
  discard await client.sendRequest("disconnect", newJObject())
  client.state = dapReady

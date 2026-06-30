## AI Service Thread
## Communicates with Kimi Code CLI via ACP (Agent Communication Protocol)
## ACP is JSON-RPC 2.0 over stdio.

import std/[options, json, os, osproc, strutils, streams, atomics]
when defined(windows):
  import std/winlean
else:
  import std/posix
import ../channel_spsc
import ../core/config
import builtin_ai
import git as gitcmd

type
  AIMessageKind* = enum
    amkSendMessage
    amkResponseChunk
    amkResponseDone
    amkError
    amkReady
    amkThinking
    amkFileChanged
    amkNewSession
    amkClearSession
    amkShutdown
    amkCancel

  AIMessage* = object
    kind*: AIMessageKind
    text*: string
    error*: string

  AIThread* = ref object
    reqChan: SPSChannel[AIMessage]
    respChan: SPSChannel[AIMessage]
    thread: Thread[AIThread]
    isReady*: Atomic[bool]
    workspaceRoot*: string
    config*: AppConfig
    shuttingDown*: Atomic[bool]
    history: seq[ChatTurn]   ## Multi-turn conversation memory (built-in HTTP agent)

const
  MaxHistoryTurns* = 20   ## Cap conversation history to bound memory growth.

proc sendResponse(t: AIThread, msg: AIMessage) {.inline.} =
  if t.respChan.isClosed or t.shuttingDown.load(moAcquire):
    return
  var retries = 0
  while not channel_spsc.trySend(t.respChan, msg):
    if t.respChan.isClosed or t.shuttingDown.load(moAcquire):
      return
    if retries < 100:
      sleep(1)
      inc retries
    else:
      stderr.writeLine("[ai-thread] WARNING: dropped response, channel full after 100ms")
      break

proc blockingRead(fd: FileHandle): string =
  var buf: array[4096, char]
  when defined(windows):
    var bytesRead: DWORD
    if winlean.readFile(fd, addr buf[0], 4096.DWORD, addr bytesRead, nil).bool and bytesRead > 0:
      result = newString(bytesRead.int)
      copyMem(addr result[0], addr buf[0], bytesRead.int)
  else:
    while true:
      let n = posix.read(fd.int32, addr buf[0], 4096)
      if n > 0:
        result = newString(n)
        copyMem(addr result[0], addr buf[0], n)
        return
      elif n == 0:
        return ""
      else:
        let err = errno
        if err == EAGAIN or err == EINTR:
          continue
        stderr.writeLine("[ai-thread] read error, errno=" & $err)
        return ""

type
  ReaderThreadArgs = object
    fd: FileHandle
    chan: SPSChannel[string]

proc readerProc(args: ReaderThreadArgs) {.thread.} =
  while true:
    let data = blockingRead(args.fd)
    while not channel_spsc.trySend(args.chan, data):
      if args.chan.isClosed:
        return
      sleep(1)
    if data.len == 0:
      break

proc sendJsonRpc(p: Process, id: int, rpcMethod: string, params: JsonNode): int =
  let msg = %*{"jsonrpc": "2.0", "id": id, "method": rpcMethod, "params": params}
  p.inputStream.writeLine($msg)
  p.inputStream.flush()
  return id + 1

proc sendJsonRpcNotification(p: Process, rpcMethod: string, params: JsonNode) =
  let msg = %*{"jsonrpc": "2.0", "method": rpcMethod, "params": params}
  try:
    p.inputStream.writeLine($msg)
    p.inputStream.flush()
  except CatchableError as e:
    stderr.writeLine("[ai-thread] failed to send notification " & rpcMethod & ": " & e.msg)

proc sendJsonRpcResponse(p: Process, id: int, result: JsonNode) =
  let msg = %*{"jsonrpc": "2.0", "id": id, "result": result}
  p.inputStream.writeLine($msg)
  p.inputStream.flush()

proc sendJsonRpcError(p: Process, id: int, code: int, message: string) =
  let msg = %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
  p.inputStream.writeLine($msg)
  p.inputStream.flush()

proc canonicalPathForCheck(path: string): string =
  ## Best-effort canonical absolute path, resolving symlinks where possible.
  if fileExists(path) or dirExists(path):
    try:
      return expandFilename(path)
    except CatchableError:
      discard
  result = normalizePathEnd(absolutePath(path), trailingSep = false)

proc isPathInsideWorkspace*(path, root: string): bool =
  ## Robust workspace containment check using normalized canonical paths.
  let absPath = canonicalPathForCheck(path)
  let normRoot = normalizePathEnd(canonicalPathForCheck(root), trailingSep = true)
  if absPath.len < normRoot.len:
    return false
  return absPath.startsWith(normRoot)

proc handleAgentRequest(t: AIThread, p: Process, j: JsonNode) =
  let reqId = j["id"].getInt()
  let rpcMethod = j["method"].getStr()
  let params = if j.hasKey("params"): j["params"] else: newJObject()

  case rpcMethod
  of "fs/read_text_file":
    let path = params{"path"}.getStr()
    let absPath = absolutePath(path)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      sendJsonRpcError(p, reqId, -32000, "Access denied: path outside workspace")
    elif fileExists(absPath):
      try:
        let content = readFile(absPath)
        sendJsonRpcResponse(p, reqId, %*{"text": content})
      except CatchableError as e:
        sendJsonRpcError(p, reqId, -32000, "Failed to read file: " & e.msg)
    else:
      sendJsonRpcError(p, reqId, -32000, "File not found: " & absPath)

  of "fs/write_text_file":
    let path = params{"path"}.getStr()
    let content = params{"content"}.getStr()
    let absPath = absolutePath(path)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      sendJsonRpcError(p, reqId, -32000, "Access denied: path outside workspace")
    else:
      try:
        writeFile(absPath, content)
        sendJsonRpcResponse(p, reqId, newJObject())
        t.sendResponse(AIMessage(kind: amkFileChanged, text: absPath))
      except CatchableError as e:
        sendJsonRpcError(p, reqId, -32000, "Failed to write file: " & e.msg)

  of "fs/list_directory":
    let path = params{"path"}.getStr()
    let absPath = absolutePath(path)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      sendJsonRpcError(p, reqId, -32000, "Access denied: path outside workspace")
    elif dirExists(absPath):
      try:
        var entries: seq[JsonNode]
        for kind, entryPath in walkDir(absPath):
          let name = extractFilename(entryPath)
          let entryType = case kind
            of pcFile, pcLinkToFile: "file"
            of pcDir, pcLinkToDir: "directory"
          entries.add(%*{ "name": name, "type": entryType })
        sendJsonRpcResponse(p, reqId, %*{"entries": entries})
      except CatchableError as e:
        sendJsonRpcError(p, reqId, -32000, "Failed to list directory: " & e.msg)
    else:
      sendJsonRpcError(p, reqId, -32000, "Directory not found: " & absPath)

  of "tools/list":
    let tools = %*[
      { "name": "fs/read_text_file", "description": "Read the contents of a text file" },
      { "name": "fs/write_text_file", "description": "Write content to a text file" },
      { "name": "fs/list_directory", "description": "List files and directories" },
      { "name": "git/get_file_diff", "description": "Get git diff for a specific file" },
      { "name": "git/get_diff", "description": "Get full working tree diff" }
    ]
    sendJsonRpcResponse(p, reqId, %*{"tools": tools})

  of "git/get_file_diff":
    let filePath = params{"path"}.getStr()
    let repoRoot = gitcmd.getRepoRoot(filePath)
    if repoRoot.len == 0:
      sendJsonRpcError(p, reqId, -32000, "Not a git repository: " & filePath)
    else:
      let relPath = relativePath(filePath, repoRoot)
      let staged = gitcmd.getFileDiff(repoRoot, relPath, staged = true)
      let unstaged = gitcmd.getFileDiff(repoRoot, relPath, staged = false)
      var result = newJObject()
      if staged.len > 0: result["staged"] = %staged
      if unstaged.len > 0: result["unstaged"] = %unstaged
      if result.len == 0:
        result["unstaged"] = %""  # No changes
      sendJsonRpcResponse(p, reqId, result)

  of "git/get_diff":
    let repoRoot = params{"repoRoot"}.getStr()
    if repoRoot.len == 0 or not gitcmd.isGitRepository(repoRoot):
      sendJsonRpcError(p, reqId, -32000, "Not a git repository: " & repoRoot)
    else:
      let diff = gitcmd.getAllLocalDiff(repoRoot)
      sendJsonRpcResponse(p, reqId, %*{"diff": diff})

  of "session/request_permission":
    let permType = params{"permissionType"}.getStr("")
    let isWrite = permType.contains("write") or permType.contains("edit") or permType.contains("modify")
    let isExec = permType.contains("execute") or permType.contains("run") or permType.contains("shell")
    if isWrite or isExec:
      # Surface the denial to the UI so users know the agent wanted to act.
      t.sendResponse(AIMessage(kind: amkError, error: "AI requested " & permType & " permission; denied for safety. Use the CLI directly if you want to allow this action."))
      sendJsonRpcResponse(p, reqId, %*{
        "outcome": {
          "outcome": "selected",
          "optionId": "deny"
        }
      })
    elif params.hasKey("options") and params["options"].len > 0:
      var selectedId = ""
      for opt in params["options"]:
        let kind = opt{"kind"}.getStr()
        if kind.startsWith("allow"):
          selectedId = opt{"optionId"}.getStr()
          break
      if selectedId.len == 0:
        selectedId = params["options"][0]{"optionId"}.getStr()
      sendJsonRpcResponse(p, reqId, %*{
        "outcome": {
          "outcome": "selected",
          "optionId": selectedId
        }
      })
    else:
      sendJsonRpcError(p, reqId, -32000, "No permission options provided")

  else:
    stderr.writeLine("[ai-thread] unhandled agent request: " & rpcMethod)
    sendJsonRpcError(p, reqId, -32601, "Method not found: " & rpcMethod)

# ---------------------------------------------------------------------------
#  Templates / helpers shared by init, session creation, and the main loop
# ---------------------------------------------------------------------------

const MaxLineBuffer = 1_000_000

template drainReader(chan: SPSChannel[string], buf: var string, body: untyped) =
  ## Read everything currently waiting on ``chan``, split into lines, and
  ## execute ``body`` for each complete line (``j`` is injected as the parsed
  ## JsonNode).
  var data: string
  while channel_spsc.tryReceive(chan, data):
    if data.len == 0: continue
    buf &= data
    if buf.len > MaxLineBuffer:
      # Find the last newline within the safe window so we don't split mid-line
      let lastNl = buf.rfind('\n', 0, MaxLineBuffer - 1)
      if lastNl >= 0:
        let safe = buf[0..lastNl]
        buf = buf[lastNl + 1..^1]
        var lines = safe.split('\n')
        # safe ends with '\n', so pop() yields "" which we discard
        discard lines.pop()
        for line in lines:
          if line.len == 0: continue
          try:
            let j {.inject.} = parseJson(line)
            body
          except CatchableError as e:
            stderr.writeLine("[ai-thread] parse error: " & e.msg & " | line: " & line[0..min(80, line.len-1)])
      else:
        # No newline found in first 1MB — runaway line. Log and discard head.
        stderr.writeLine("[ai-thread] WARNING: runaway line exceeds " & $MaxLineBuffer & " bytes, discarding head")
        buf = buf[MaxLineBuffer..^1]
    else:
      var lines = buf.split('\n')
      buf = lines.pop()
      for line in lines:
        if line.len == 0: continue
        try:
          let j {.inject.} = parseJson(line)
          body
        except CatchableError as e:
          stderr.writeLine("[ai-thread] parse error: " & e.msg & " | line: " & line[0..min(80, line.len-1)])

proc drainStaleChunks(readerChan: SPSChannel[string]) =
  var staleData: string
  while channel_spsc.tryReceive(readerChan, staleData):
    discard

proc cancelCurrentTurn(p: Process, sessionId: string, pendingTurnId: var int,
                       cancelled: var bool, readerChan: SPSChannel[string]) =
  if pendingTurnId >= 0 and sessionId.len > 0:
    sendJsonRpcNotification(p, "session/cancel", %*{ "sessionId": sessionId, "id": pendingTurnId })
  cancelled = true
  pendingTurnId = -1
  drainStaleChunks(readerChan)

proc handleAgentJson(t: AIThread, p: Process, j: JsonNode,
                     sessionId: var string, sessionDone: var bool,
                     pendingTurnId: var int, cancelled: bool) =
  ## Dispatch JSON-RPC messages that arrive during the main conversation loop.
  if j.hasKey("result") and j.hasKey("id"):
    if not sessionDone and j["result"].hasKey("sessionId"):
      sessionId = j["result"]["sessionId"].getStr()
      sessionDone = true
    elif j["id"].getInt() == pendingTurnId:
      pendingTurnId = -1
      if not cancelled:
        t.sendResponse(AIMessage(kind: amkResponseDone))
  elif j.hasKey("error") and j.hasKey("id"):
    if j["id"].getInt() == pendingTurnId:
      pendingTurnId = -1
      if not cancelled:
        t.sendResponse(AIMessage(kind: amkError, error: j["error"]["message"].getStr()))
  elif j.hasKey("method") and j.hasKey("id"):
    t.handleAgentRequest(p, j)
  elif j.hasKey("method") and not j.hasKey("id"):
    let rpcMethod = j["method"].getStr()
    if rpcMethod == "session/update":
      let update = j["params"]["update"]
      let updateType = update["sessionUpdate"].getStr()
      case updateType
      of "agent_message_chunk":
        if not cancelled:
          t.sendResponse(AIMessage(kind: amkResponseChunk, text: update["content"].getStr()))
      of "agent_thought_chunk":
        if not cancelled:
          var text = ""
          let contentNode = update["content"]
          if contentNode.kind == JString:
            text = contentNode.getStr()
          elif contentNode.kind == JObject:
            for key in ["text", "thought", "reasoning", "content", "message"]:
              if contentNode.hasKey(key) and contentNode[key].kind == JString:
                text = contentNode[key].getStr()
                break
          if text.len > 0:
            t.sendResponse(AIMessage(kind: amkThinking, text: text))
      of "tool_call_start":
        stderr.writeLine("[ai-thread] tool_call_start")
      of "tool_call_progress":
        discard
      else:
        discard

# ---------------------------------------------------------------------------
#  Main thread procedure
# ---------------------------------------------------------------------------

proc buildAICommand(config: AppConfig): tuple[cmd: string, args: seq[string], error: string] =
  ## Build the ACP-compatible command for the configured AI provider.
  ## Falls back to config.aiCommand for unknown providers or custom setups.
  let provider = config.aiAgent.toLowerAscii()

  case provider
  of "", "kimi":
    result.args = @["acp"]
    if config.aiModel.len > 0:
      result.args = @["--model", config.aiModel, "acp"]
    result.cmd = "kimi"
  of "claude":
    # Requires the claude-code-acp bridge (e.g. npm install -g @anthropic-ai/claude-code-acp)
    result.cmd = "claude-code-acp"
    result.args = @[]
  of "opencode":
    # Requires the opencode-ai ACP adapter (e.g. npx -y opencode-ai acp)
    result.cmd = "npx"
    result.args = @["-y", "opencode-ai", "acp"]
  of "gemini":
    # Requires the Gemini CLI with ACP support (e.g. gemini --acp)
    result.cmd = "gemini"
    result.args = @["--acp"]
  of "codex":
    # Requires the OpenAI Codex CLI with ACP support (e.g. codex acp)
    result.cmd = "codex"
    result.args = @["acp"]
  of "cursor":
    # Requires the Cursor CLI/agent with ACP support (e.g. cursor-agent acp)
    result.cmd = "cursor-agent"
    result.args = @["acp"]
  of "custom":
    if config.aiCommand.len == 0:
      return ("", @[], "Custom AI provider requires aiCommand")
    let parts = config.aiCommand.splitWhitespace()
    result.cmd = parts[0]
    result.args = if parts.len > 1: parts[1..^1] else: @[]
  else:
    if isHttpAgent(provider):
      return ("", @[], provider.capitalizeAscii() & " is a built-in HTTP provider; set aiBaseUrl and aiApiKey")
    if config.aiCommand.len > 0:
      let parts = config.aiCommand.splitWhitespace()
      result.cmd = parts[0]
      result.args = if parts.len > 1: parts[1..^1] else: @[]
    else:
      return ("", @[], "Unsupported AI provider: " & config.aiAgent & "; set aiCommand or choose a built-in provider")

proc shutdownAIProcess(p: Process, readerChan: var SPSChannel[string],
                       readerThread: var Thread[ReaderThreadArgs]) =
  try:
    sendJsonRpcNotification(p, "session/close", newJObject())
  except CatchableError:
    discard
  var waited = 0
  while waited < 300:
    if peekExitCode(p) != -1:
      break
    sleep(1)
    inc waited
  try:
    if peekExitCode(p) == -1:
      p.terminate()
    p.close()
  except CatchableError:
    discard
  readerChan.close()
  joinThread(readerThread)

proc runBuiltinAI(t: AIThread) {.thread.} =
  ## Worker path for the built-in HTTP agent.
  t.isReady.store(true, moRelease)
  t.sendResponse(AIMessage(kind: amkReady))
  while true:
    var req: AIMessage
    while not channel_spsc.tryReceive(t.reqChan, req):
      if t.reqChan.isClosed or t.shuttingDown.load(moAcquire):
        return
      sleep(1)
    if t.shuttingDown.load(moAcquire):
      return
    case req.kind
    of amkSendMessage:
      var promptText = req.text
      # Use the lightweight model to detect git-related intent ONCE, then attach
      # local status + diff so the main model can answer without tool access.
      let isGitIntent = classifyGitIntent(t.config, req.text)
      if isGitIntent:
        let gitContext = buildGitContextPrompt(t.workspaceRoot, req.text)
        if gitContext.len > 0:
          promptText = gitContext
      # Send the prompt with multi-turn conversation history for context memory.
      let answer = doChatCompletionHistory(t.config, promptText, t.history)
      if answer.startsWith("HTTP error") or answer.startsWith("Request failed") or answer.startsWith("Unexpected response"):
        t.sendResponse(AIMessage(kind: amkError, error: answer))
      else:
        # Record this turn into history (user prompt + assistant reply).
        t.history.add((role: ChatRoleUser, content: req.text))
        t.history.add((role: ChatRoleAssistant, content: answer))
        # Prune oldest turns to bound memory growth.
        while t.history.len > MaxHistoryTurns * 2:
          t.history.delete(0)
        # Agent-like execution: if the user asked to commit local changes and we
        # attached git context, treat the model output as the commit message,
        # stage all changes, commit, and report the result.
        var finalText = answer
        if promptText != req.text and isGitIntent:
          let message = answer.strip()
          if message.len > 0:
            if gitcmd.stageAllChanges(t.workspaceRoot) and gitcmd.commitChanges(t.workspaceRoot, message):
              finalText = "Committed with message:\n\n" & message
            else:
              finalText = "Generated commit message:\n\n" & message & "\n\n(commit failed)"
        t.sendResponse(AIMessage(kind: amkResponseChunk, text: finalText))
        t.sendResponse(AIMessage(kind: amkResponseDone))
    of amkNewSession, amkClearSession:
      # Start a fresh conversation: clear multi-turn history.
      t.history.setLen(0)
    of amkShutdown:
      break
    of amkCancel:
      discard
    else:
      discard

proc aiThreadProc(t: AIThread) {.thread.} =
  if isHttpAgent(t.config.aiAgent):
    runBuiltinAI(t)
    return

  let (cmd, args, cmdError) = buildAICommand(t.config)
  if cmd.len == 0:
    t.sendResponse(AIMessage(kind: amkError, error: cmdError))
    return

  var p: Process
  try:
    p = startProcess(cmd, args = args, options = {poUsePath})
  except CatchableError as e:
    t.sendResponse(AIMessage(kind: amkError, error: "Failed to start " & cmd & ": " & e.msg))
    return

  let outFd = outputHandle(p)
  var readerChan = newSPSChannel[string](1024)
  var readerThread: Thread[ReaderThreadArgs]
  createThread(readerThread, readerProc, ReaderThreadArgs(fd: outFd, chan: readerChan))

  var nextId = 1
  var lineBuffer = ""
  var sessionId = ""
  var sessionDone = false
  var pendingTurnId = -1
  var cancelled = false

  template bail(msg: string) =
    t.sendResponse(AIMessage(kind: amkError, error: msg))
    shutdownAIProcess(p, readerChan, readerThread)
    return

  template checkDead: bool = peekExitCode(p) != -1

  # --- Initialize ---
  nextId = sendJsonRpc(p, nextId, "initialize", %*{
    "protocolVersion": 1,
    "clientInfo": {"name": "drift", "version": "0.1"}
  })

  var initDone = false
  while not initDone:
    drainReader(readerChan, lineBuffer):
      if j.hasKey("result") and j.hasKey("id"):
        initDone = true
        t.isReady.store(true, moRelease)
        t.sendResponse(AIMessage(kind: amkReady))
      elif j.hasKey("error") and j.hasKey("id"):
        bail("ACP init failed: " & j["error"]["message"].getStr())
    if checkDead():
      bail(cmd & " exited during init")
    sleep(1)

  # --- Create session ---
  proc createSession() =
    nextId = sendJsonRpc(p, nextId, "session/new", %*{"cwd": t.workspaceRoot, "mcpServers": []})

  createSession()

  while not sessionDone:
    drainReader(readerChan, lineBuffer):
      if j.hasKey("result") and j.hasKey("id") and j["result"].hasKey("sessionId"):
        sessionId = j["result"]["sessionId"].getStr()
        sessionDone = true
      elif j.hasKey("error") and j.hasKey("id"):
        bail("ACP session/new failed: " & j["error"]["message"].getStr())
    if checkDead():
      bail(cmd & " exited during session creation")
    sleep(1)

  if sessionId.len == 0:
    bail("ACP session creation returned no sessionId")

  # --- Main loop ---
  while true:
    var reqMsg: AIMessage
    if channel_spsc.tryReceive(t.reqChan, reqMsg):
      case reqMsg.kind
      of amkSendMessage:
        if pendingTurnId >= 0:
          cancelCurrentTurn(p, sessionId, pendingTurnId, cancelled, readerChan)
        drainStaleChunks(readerChan)
        let reqId = nextId
        nextId = sendJsonRpc(p, nextId, "session/prompt", %*{
          "sessionId": sessionId,
          "prompt": [{"type": "text", "text": reqMsg.text}]
        })
        pendingTurnId = reqId
        cancelled = false
      of amkNewSession:
        sessionDone = false
        createSession()
      of amkClearSession:
        sessionDone = false
        createSession()
      of amkCancel:
        cancelCurrentTurn(p, sessionId, pendingTurnId, cancelled, readerChan)
      of amkShutdown:
        shutdownAIProcess(p, readerChan, readerThread)
        return
      else:
        discard

    drainReader(readerChan, lineBuffer):
      handleAgentJson(t, p, j, sessionId, sessionDone, pendingTurnId, cancelled)

    if checkDead():
      t.sendResponse(AIMessage(kind: amkError, error: cmd & " process exited"))
      break

    sleep(1)

  shutdownAIProcess(p, readerChan, readerThread)

# ---------------------------------------------------------------------------
#  Public API
# ---------------------------------------------------------------------------

proc newAIThread*(config: AppConfig = defaultConfig()): AIThread =
  result = AIThread(
    reqChan: newSPSChannel[AIMessage](64),
    respChan: newSPSChannel[AIMessage](512),
    workspaceRoot: absolutePath(getCurrentDir()),
    config: config
  )
  result.isReady.store(false, moRelaxed)
  result.shuttingDown.store(false, moRelaxed)
  createThread(result.thread, aiThreadProc, result)

proc getResponse*(t: AIThread): Option[AIMessage] =
  var msg: AIMessage
  if channel_spsc.tryReceive(t.respChan, msg):
    return some(msg)
  return none(AIMessage)

proc sendOrWarn[T](c: SPSChannel[T], msg: T, name: string) =
  var retries = 0
  while not channel_spsc.trySend(c, msg):
    if c.isClosed: return
    if retries < 50:
      sleep(1)
      inc retries
    else:
      stderr.writeLine("[ai-thread] WARNING: dropped " & name & ", channel full")
      break

proc sendMessage*(t: AIThread, text: string) =
  sendOrWarn(t.reqChan, AIMessage(kind: amkSendMessage, text: text), "sendMessage")

proc newSession*(t: AIThread) =
  sendOrWarn(t.reqChan, AIMessage(kind: amkNewSession), "newSession")

proc clearSession*(t: AIThread) =
  sendOrWarn(t.reqChan, AIMessage(kind: amkClearSession), "clearSession")

proc cancel*(t: AIThread) =
  sendOrWarn(t.reqChan, AIMessage(kind: amkCancel), "cancel")

proc shutdown*(t: AIThread) =
  if t.shuttingDown.exchange(true, moAcquire):
    return
  sendOrWarn(t.reqChan, AIMessage(kind: amkShutdown), "shutdown")
  t.respChan.close()
  t.reqChan.close()

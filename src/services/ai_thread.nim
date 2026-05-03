## AI Service Thread
## Communicates with Kimi Code CLI via ACP (Agent Communication Protocol)
## ACP is JSON-RPC 2.0 over stdio.

import std/[options, json, os, osproc, strutils, streams]
import std/posix
import ../channel_spsc
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
    isReady*: bool
    workspaceRoot*: string

proc sendResponse(t: AIThread, msg: AIMessage) {.inline.} =
  if t.respChan.isClosed: return
  var retries = 0
  while not channel_spsc.trySend(t.respChan, msg):
    if t.respChan.isClosed: return
    if retries < 100:
      discard usleep(1000)  # 1ms backoff
      inc retries
    else:
      stderr.writeLine("[ai-thread] WARNING: dropped response, channel full after 100ms")
      break

proc setNonBlocking(fd: FileHandle) =
  let fd32 = fd.int32
  var flags = fcntl(fd32, F_GETFL, 0)
  discard fcntl(fd32, F_SETFL, flags or O_NONBLOCK)

proc readAvailable(fd: FileHandle): string =
  var buf: array[4096, char]
  result = ""
  while true:
    let n = posix.read(fd.int32, addr buf[0], 4096)
    if n > 0:
      var s = newString(n)
      copyMem(addr s[0], addr buf[0], n)
      result.add(s)
    elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
      break
    else:
      break

proc sendJsonRpc(p: Process, id: int, rpcMethod: string, params: JsonNode): int =
  let msg = %*{"jsonrpc": "2.0", "id": id, "method": rpcMethod, "params": params}
  p.inputStream.writeLine($msg)
  p.inputStream.flush()
  return id + 1

proc sendJsonRpcResponse(p: Process, id: int, result: JsonNode) =
  let msg = %*{"jsonrpc": "2.0", "id": id, "result": result}
  p.inputStream.writeLine($msg)
  p.inputStream.flush()

proc sendJsonRpcError(p: Process, id: int, code: int, message: string) =
  let msg = %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
  p.inputStream.writeLine($msg)
  p.inputStream.flush()

proc handleAgentRequest(t: AIThread, p: Process, j: JsonNode) =
  let reqId = j["id"].getInt()
  let rpcMethod = j["method"].getStr()
  let params = if j.hasKey("params"): j["params"] else: newJObject()

  case rpcMethod
  of "fs/read_text_file":
    let path = params{"path"}.getStr()
    let absPath = absolutePath(path)
    if not absPath.startsWith(t.workspaceRoot):
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
    if not absPath.startsWith(t.workspaceRoot):
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
    if not absPath.startsWith(t.workspaceRoot):
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
    # Require explicit user approval for dangerous operations
    let permType = params{"permissionType"}.getStr("")
    let isWrite = permType.contains("write") or permType.contains("edit") or permType.contains("modify")
    let isExec = permType.contains("execute") or permType.contains("run") or permType.contains("shell")
    if isWrite or isExec:
      # Deny write/execute permissions automatically — user must use editor directly
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

proc aiThreadProc(t: AIThread) {.thread.} =
  var p: Process
  try:
    p = startProcess("kimi", args = @["acp"], options = {poUsePath})
  except CatchableError as e:
    t.sendResponse(AIMessage(kind: amkError, error: "Failed to start kimi acp: " & e.msg))
    return

  let outFd = outputHandle(p)
  setNonBlocking(outFd)

  # --- Initialize ---
  var nextId = 1
  nextId = sendJsonRpc(p, nextId, "initialize", %*{
    "protocolVersion": 1,
    "clientInfo": {"name": "drift", "version": "0.1"}
  })

  var initDone = false
  var sessionId = ""
  var lineBuffer = ""
  var initRetries = 0

  while not initDone:
    discard usleep(10000)
    inc initRetries
    if initRetries > 500:  # 5 second timeout
      t.sendResponse(AIMessage(kind: amkError, error: "ACP init timeout"))
      return
    let data = readAvailable(outFd)
    if data.len > 0:
      lineBuffer &= data
      var lines = lineBuffer.split('\n')
      lineBuffer = lines.pop()
      for line in lines:
        if line.len == 0: continue
        try:
          let j = parseJson(line)
          if j.hasKey("result") and j.hasKey("id"):
            initDone = true
            t.isReady = true
            t.sendResponse(AIMessage(kind: amkReady))
          elif j.hasKey("error"):
            let errMsg = j["error"]["message"].getStr()
            t.sendResponse(AIMessage(kind: amkError, error: "ACP init failed: " & errMsg))
            return
        except CatchableError as e:
          stderr.writeLine("[ai-thread] parse error during init: " & e.msg)

    if peekExitCode(p) != -1:
      t.sendResponse(AIMessage(kind: amkError, error: "kimi acp exited during init"))
      return

  # --- Create session ---
  proc createSession() =
    nextId = sendJsonRpc(p, nextId, "session/new", %*{"cwd": getCurrentDir(), "mcpServers": []})

  createSession()

  var sessionDone = false
  var sessionRetries = 0
  while not sessionDone:
    discard usleep(10000)
    inc sessionRetries
    if sessionRetries > 500:  # 5 second timeout
      t.sendResponse(AIMessage(kind: amkError, error: "ACP session creation timeout"))
      return
    let data = readAvailable(outFd)
    if data.len > 0:
      lineBuffer &= data
      var lines = lineBuffer.split('\n')
      lineBuffer = lines.pop()
      for line in lines:
        if line.len == 0: continue
        try:
          let j = parseJson(line)
          if j.hasKey("result") and j.hasKey("id"):
            if j["result"].hasKey("sessionId"):
              sessionId = j["result"]["sessionId"].getStr()
              sessionDone = true
          elif j.hasKey("error"):
            let errMsg = j["error"]["message"].getStr()
            t.sendResponse(AIMessage(kind: amkError, error: "ACP session/new failed: " & errMsg))
            return
        except CatchableError as e:
          stderr.writeLine("[ai-thread] parse error during session/new: " & e.msg)

    if peekExitCode(p) != -1:
      t.sendResponse(AIMessage(kind: amkError, error: "kimi acp exited during session creation"))
      return

  if sessionId.len == 0:
    t.sendResponse(AIMessage(kind: amkError, error: "ACP session creation returned no sessionId"))
    return

  # --- Main loop ---
  var pendingTurnId = -1
  var cancelled = false

  while true:
    # Check for requests from app
    var reqMsg: AIMessage
    if channel_spsc.tryReceive(t.reqChan, reqMsg):
      case reqMsg.kind
      of amkSendMessage:
        let reqId = nextId
        nextId = sendJsonRpc(p, nextId, "session/prompt", %*{
          "sessionId": sessionId,
          "prompt": [
            {"type": "text", "text": reqMsg.text}
          ]
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
        cancelled = true
        pendingTurnId = -1
      of amkShutdown:
        try:
          p.terminate()
        except CatchableError:
          discard
        break
      else:
        discard

    # Check for output from kimi
    let data = readAvailable(outFd)
    if data.len > 0:
      lineBuffer &= data
      var lines = lineBuffer.split('\n')
      lineBuffer = lines.pop()
      for line in lines:
        if line.len == 0: continue
        try:
          let j = parseJson(line)
          if j.hasKey("method") and j.hasKey("id"):
            # Request from agent (tool call)
            t.handleAgentRequest(p, j)
          elif j.hasKey("method") and not j.hasKey("id"):
            # Notification from agent
            let rpcMethod = j["method"].getStr()
            if rpcMethod == "session/update":
              let update = j["params"]["update"]
              let updateType = update["sessionUpdate"].getStr()
              case updateType
              of "agent_message_chunk":
                if not cancelled:
                  let text = update["content"].getStr()
                  t.sendResponse(AIMessage(kind: amkResponseChunk, text: text))
              of "agent_thought_chunk":
                if not cancelled:
                  var text = ""
                  if update.hasKey("content"):
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
          elif j.hasKey("result") and j.hasKey("id"):
            # Response to our request
            let respId = j["id"].getInt()
            if not sessionDone and j["result"].hasKey("sessionId"):
              sessionId = j["result"]["sessionId"].getStr()
              sessionDone = true
            elif respId == pendingTurnId:
              pendingTurnId = -1
              if not cancelled:
                t.sendResponse(AIMessage(kind: amkResponseDone))
          elif j.hasKey("error") and j.hasKey("id"):
            let respId = j["id"].getInt()
            if respId == pendingTurnId:
              pendingTurnId = -1
              if not cancelled:
                let errMsg = j["error"]["message"].getStr()
                t.sendResponse(AIMessage(kind: amkError, error: errMsg))
        except CatchableError as e:
          stderr.writeLine("[ai-thread] parse error: " & e.msg & " | line: " & line[0..min(80, line.len-1)])

    if peekExitCode(p) != -1:
      t.sendResponse(AIMessage(kind: amkError, error: "kimi acp process exited"))
      break

    discard usleep(5000)  # 5ms

proc newAIThread*(): AIThread =
  result = AIThread(
    reqChan: newSPSChannel[AIMessage](64),
    respChan: newSPSChannel[AIMessage](512),
    isReady: false,
    workspaceRoot: absolutePath(getCurrentDir())
  )
  createThread(result.thread, aiThreadProc, result)

proc getResponse*(t: AIThread): Option[AIMessage] =
  var msg: AIMessage
  if channel_spsc.tryReceive(t.respChan, msg):
    return some(msg)
  return none(AIMessage)

proc sendMessage*(t: AIThread, text: string) =
  discard channel_spsc.trySend(t.reqChan, AIMessage(kind: amkSendMessage, text: text))

proc newSession*(t: AIThread) =
  discard channel_spsc.trySend(t.reqChan, AIMessage(kind: amkNewSession))

proc clearSession*(t: AIThread) =
  discard channel_spsc.trySend(t.reqChan, AIMessage(kind: amkClearSession))

proc cancel*(t: AIThread) =
  discard channel_spsc.trySend(t.reqChan, AIMessage(kind: amkCancel))

proc shutdown*(t: AIThread) =
  discard channel_spsc.trySend(t.reqChan, AIMessage(kind: amkShutdown))
  t.respChan.close()
  t.reqChan.close()

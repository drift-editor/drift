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
import prompt_complexity
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
    amkEditPreview       ## Sent from AI thread to UI: show diff, wait for confirm
    amkEditConfirm       ## Sent from UI to AI thread: accept (text="ok") or reject (text="reject")
    amkNewSession
    amkClearSession
    amkShutdown
    amkCancel
    amkTogglePlanMode

  AIMessage* = object
    kind*: AIMessageKind
    text*: string
    error*: string
    previewPath*: string    ## For amkEditPreview: the file path
    previewOld*: string     ## For amkEditPreview: original content
    previewNew*: string     ## For amkEditPreview: proposed new content
    previewSummary*: string ## For amkEditPreview: human-readable summary

  AIThread* = ref object
    reqChan: SPSChannel[AIMessage]
    respChan: SPSChannel[AIMessage]
    thread: Thread[AIThread]
    isReady*: Atomic[bool]
    workspaceRoot*: string
    config*: AppConfig
    shuttingDown*: Atomic[bool]
    history: seq[ChatTurn]   ## Multi-turn conversation memory (built-in HTTP agent)
    planMode*: bool          ## Plan mode: generate plan before executing

const
  MaxHistoryTurns* = 20   ## Cap conversation history to bound memory growth.
  MaxAgenticIterations* = 100  ## Max tool-call rounds per built-in agent turn.

  PlanModePrompt* = """
Plan mode is active. You MUST NOT make any edits or execute any changes yet.

Your task is to create a detailed implementation plan. Follow this structure:

### Phase 1: Initial Understanding
- Read and understand the relevant code
- Ask clarifying questions if needed
- Identify files that need to be modified

### Phase 2: Design
- Describe the implementation approach
- List all files to be modified or created
- Identify dependencies and edge cases

### Phase 3: Final Plan
Write your plan as a markdown checklist:
- [ ] Step 1: Description
- [ ] Step 2: Description
- ...

Include file paths and specific code references. Be concise but actionable.

After writing the plan, tell the user: "Plan ready. Switch to Build mode to execute."
"""

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

proc resolveWorkspacePath*(path, root: string): string =
  ## Resolve a relative path against the workspace root (not CWD).
  ## Absolute paths are canonicalized directly.
  if path.isAbsolute: canonicalPathForCheck(path)
  else: canonicalPathForCheck(root / path)

const MaxFileWriteSize* = 10_000_000  ## 10 MB per-file write cap for ACP agents.

proc handleAgentRequest(t: AIThread, p: Process, j: JsonNode) =
  let reqId = j["id"].getInt()
  let rpcMethod = j["method"].getStr()
  let params = if j.hasKey("params"): j["params"] else: newJObject()

  case rpcMethod
  of "fs/read_text_file":
    let path = params{"path"}.getStr()
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
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
    if content.len > MaxFileWriteSize:
      sendJsonRpcError(p, reqId, -32000, "Content too large (max " & $MaxFileWriteSize & " bytes)")
      return
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
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
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
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

  of "fs/delete":
    let filePath = params{"path"}.getStr()
    let absPath = resolveWorkspacePath(filePath, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      sendJsonRpcError(p, reqId, -32000, "Access denied: path outside workspace")
    elif sameFile(absPath, t.workspaceRoot) or absPath == t.workspaceRoot:
      sendJsonRpcError(p, reqId, -32000, "Refused: cannot delete workspace root")
    elif dirExists(absPath):
      var nonEmpty = false
      try:
        for _, _ in walkDir(absPath):
          nonEmpty = true
          break
        if nonEmpty:
          sendJsonRpcError(p, reqId, -32000, "Directory not empty; delete contents first or use fs/delete_dir")
          return
      except CatchableError:
        sendJsonRpcError(p, reqId, -32000, "Failed to read directory: " & absPath)
        return
      try:
        removeDir(absPath)
        sendJsonRpcResponse(p, reqId, %*{"success": true, "message": "Deleted directory: " & filePath})
        t.sendResponse(AIMessage(kind: amkFileChanged, text: absPath))
      except CatchableError as e:
        sendJsonRpcError(p, reqId, -32000, "Failed to delete directory: " & e.msg)
    elif fileExists(absPath):
      try:
        removeFile(absPath)
        sendJsonRpcResponse(p, reqId, %*{"success": true, "message": "Deleted file: " & filePath})
        t.sendResponse(AIMessage(kind: amkFileChanged, text: absPath))
      except CatchableError as e:
        sendJsonRpcError(p, reqId, -32000, "Failed to delete file: " & e.msg)
    else:
      sendJsonRpcError(p, reqId, -32000, "Path not found: " & filePath)

  of "fs/delete_dir":
    let filePath = params{"path"}.getStr()
    let absPath = resolveWorkspacePath(filePath, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      sendJsonRpcError(p, reqId, -32000, "Access denied: path outside workspace")
    elif sameFile(absPath, t.workspaceRoot) or absPath == t.workspaceRoot:
      sendJsonRpcError(p, reqId, -32000, "Refused: cannot delete workspace root")
    elif dirExists(absPath):
      try:
        removeDir(absPath)
        sendJsonRpcResponse(p, reqId, %*{"success": true, "message": "Deleted directory: " & filePath})
        t.sendResponse(AIMessage(kind: amkFileChanged, text: absPath))
      except CatchableError as e:
        sendJsonRpcError(p, reqId, -32000, "Failed to delete directory: " & e.msg)
    else:
      sendJsonRpcError(p, reqId, -32000, "Directory not found: " & filePath)

  of "tools/list":
    let tools = %*[
      { "name": "fs/read_text_file",
        "description": "Read the contents of a text file",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the file (relative to workspace or absolute)" }
          },
          "required": ["path"]
        }
      },
      { "name": "fs/write_text_file",
        "description": "Write content to a text file (max 10 MB)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the file (relative to workspace or absolute)" },
            "content": { "type": "string", "description": "Content to write" }
          },
          "required": ["path", "content"]
        }
      },
      { "name": "fs/list_directory",
        "description": "List files and directories in a path",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the directory (relative to workspace or absolute)" }
          },
          "required": ["path"]
        }
      },
      { "name": "fs/delete",
        "description": "Delete a file or empty directory",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to delete (relative to workspace or absolute)" }
          },
          "required": ["path"]
        }
      },
      { "name": "fs/delete_dir",
        "description": "Delete a directory and all its contents (recursive)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the directory (relative to workspace or absolute)" }
          },
          "required": ["path"]
        }
      },
      { "name": "git/get_file_diff",
        "description": "Get git diff for a specific file (staged and unstaged)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the file (repo root is auto-detected)" }
          },
          "required": ["path"]
        }
      },
      { "name": "git/get_diff",
        "description": "Get full working tree diff (HEAD vs working tree)",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to a file or directory in the repo (repo root is auto-detected)" }
          },
          "required": ["path"]
        }
      }
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
    let filePath = params{"path"}.getStr()
    let repoRoot = gitcmd.getRepoRoot(filePath)
    if repoRoot.len == 0:
      sendJsonRpcError(p, reqId, -32000, "Not a git repository: " & filePath)
    else:
      let diff = gitcmd.getAllLocalDiff(repoRoot)
      sendJsonRpcResponse(p, reqId, %*{"diff": diff, "repoRoot": repoRoot})

  of "session/request_permission":
    let permType = params{"permissionType"}.getStr("")
    let isExec = permType.contains("execute") or permType.contains("run") or permType.contains("shell")
    if isExec:
      # Deny execution permissions for safety
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

# ---------------------------------------------------------------------------
#  Direct file-operation execution (built-in HTTP agent)
# ---------------------------------------------------------------------------
# The built-in HTTP agent has no tool-use / function-calling capability, so it
# cannot mutate the filesystem through the LLM. Instead we detect clear
# imperative file-operation commands with deterministic pattern matching and
# execute them directly — the same "agentic" pattern used for git auto-commit.
# This is intentionally NOT an LLM classifier: destructive operations must be
# triggered deterministically to avoid false-positive data loss.

type
  FileOpKind* = enum
    fokNone
    fokDelete
    fokCreate
    fokMove

  FileOpIntent* = object
    kind*: FileOpKind
    path*: string       # target path (delete / create / move source)
    destPath*: string   # destination (move only)

proc stripLeadingArticleAndQualifiers(s: string): string =
  ## Strip leading articles ("the", "a", "an") always.
  ## Strip trailing type qualifiers ("directory", "folder", "file", "dir")
  ## only when the remaining text contains a path separator — "remove the
  ## docs/superpowers directory" → "docs/superpowers" but "remove the config
  ## file" is left alone to fail isPathLike, avoiding false positives.
  result = s.strip()
  for art in ["the ", "a ", "an "]:
    if result.toLowerAscii().startsWith(art):
      result = result[art.len..^1].strip()
      break
  for qual in [" directory", " folder", " file", " dir"]:
    let hasSep = result.contains('/') or result.contains('\\')
    if not hasSep: break
    if result.toLowerAscii().endsWith(qual):
      result = result[0..<(result.len - qual.len)].strip()
      break

proc unquote(s: string): string =
  ## Strip surrounding double or single quotes.
  result = s.strip()
  if result.len >= 2:
    if (result[0] == '"' and result[^1] == '"') or
       (result[0] == '\'' and result[^1] == '\''):
      result = result[1..^2]

proc isPathLike(s: string): bool =
  ## Heuristic: the string looks like a file/directory path rather than
  ## conversational text. Requires at least one of: path separator, file
  ## extension, quoted text was handled before this check.
  ## Multi-word results without path separators are rejected as ambiguous.
  if s.len == 0: return false
  if s.contains('/') or s.contains('\\'): return true
  let lower = s.toLowerAscii()
  if lower.contains(' ') or lower.contains('\t'): return false
  if s.contains('.'): return true
  for common in ["it", "me", "us", "all", "that", "this", "them", "what",
                  "which", "where", "when", "how", "why", "who", "any",
                  "some", "more", "less", "only", "just", "now", "then",
                  "here", "there", "back", "out", "in", "on", "at", "up"]:
    if lower == common: return false
  return true

proc detectFileOp*(prompt: string): FileOpIntent =
  ## Detect a clear imperative file-operation command via pattern matching.
  ## Returns fokNone if the prompt is not a direct file command.
  result = FileOpIntent(kind: fokNone)
  let p = prompt.strip()
  if p.len == 0: return
  let lower = p.toLowerAscii()

  # --- Delete / remove ---
  for verb in ["remove ", "delete ", "rm ", "del "]:
    if lower.startsWith(verb):
      let rest = stripLeadingArticleAndQualifiers(p[verb.len..^1])
      let wasQuoted = rest.strip().len >= 2 and
        ((rest.strip()[0] == '"' and rest.strip()[^1] == '"') or
         (rest.strip()[0] == '\'' and rest.strip()[^1] == '\''))
      let pathStr = unquote(rest)
      if pathStr.len > 0 and (wasQuoted or isPathLike(pathStr)):
        return FileOpIntent(kind: fokDelete, path: pathStr)
      return FileOpIntent(kind: fokNone)

  # --- Create file ---
  for verb in ["create file ", "make file ", "new file ", "touch "]:
    if lower.startsWith(verb):
      let pathStr = unquote(stripLeadingArticleAndQualifiers(p[verb.len..^1]))
      if pathStr.len > 0 and isPathLike(pathStr):
        return FileOpIntent(kind: fokCreate, path: pathStr)
      return FileOpIntent(kind: fokNone)

  # --- Move / rename ---
  for verb in ["move ", "rename ", "mv "]:
    if lower.startsWith(verb):
      let rest = p[verb.len..^1]
      let toIdx = rest.toLowerAscii().find(" to ")
      if toIdx > 0:
        let src = unquote(stripLeadingArticleAndQualifiers(rest[0..<toIdx]))
        let dst = unquote(stripLeadingArticleAndQualifiers(rest[toIdx+4..^1]))
        if src.len > 0 and dst.len > 0 and isPathLike(src) and isPathLike(dst):
          return FileOpIntent(kind: fokMove, path: src, destPath: dst)
      return FileOpIntent(kind: fokNone)

proc executeFileOp*(t: AIThread, intent: FileOpIntent): tuple[ok: bool, msg: string, paths: seq[string]] =
  ## Execute a file operation with workspace containment validation.
  result = (false, "", @[])
  if intent.kind == fokNone: return
  let absPath = if intent.path.isAbsolute: intent.path else: t.workspaceRoot / intent.path
  case intent.kind
  of fokDelete:
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return (false, "Refused: '" & intent.path & "' is outside the workspace.", @[])
    if sameFile(absPath, t.workspaceRoot) or absPath == t.workspaceRoot:
      return (false, "Refused: cannot delete the workspace root.", @[])
    if dirExists(absPath):
      try:
        removeDir(absPath)
        return (true, "Deleted directory: " & intent.path, @[absPath])
      except CatchableError as e:
        return (false, "Failed to delete directory: " & e.msg, @[])
    elif fileExists(absPath):
      try:
        removeFile(absPath)
        return (true, "Deleted file: " & intent.path, @[absPath])
      except CatchableError as e:
        return (false, "Failed to delete file: " & e.msg, @[])
    else:
      return (false, "Path not found: " & intent.path, @[])
  of fokCreate:
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return (false, "Refused: '" & intent.path & "' is outside the workspace.", @[])
    if fileExists(absPath) or dirExists(absPath):
      return (false, "Already exists: " & intent.path, @[])
    try:
      let parent = absPath.parentDir()
      if parent.len > 0 and not dirExists(parent): createDir(parent)
      writeFile(absPath, "")
      return (true, "Created file: " & intent.path, @[absPath])
    except CatchableError as e:
      return (false, "Failed to create file: " & e.msg, @[])
  of fokMove:
    let absDst = if intent.destPath.isAbsolute: intent.destPath else: t.workspaceRoot / intent.destPath
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return (false, "Refused: source '" & intent.path & "' is outside the workspace.", @[])
    if not isPathInsideWorkspace(absDst, t.workspaceRoot):
      return (false, "Refused: destination '" & intent.destPath & "' is outside the workspace.", @[])
    if not fileExists(absPath) and not dirExists(absPath):
      return (false, "Source not found: " & intent.path, @[])
    if fileExists(absDst) or dirExists(absDst):
      return (false, "Destination already exists: " & intent.destPath, @[])
    try:
      let parent = absDst.parentDir()
      if parent.len > 0 and not dirExists(parent): createDir(parent)
      moveFile(absPath, absDst)
      return (true, "Moved " & intent.path & " to " & intent.destPath, @[absPath, absDst])
    except CatchableError:
      try:
        copyFile(absPath, absDst)
        removeFile(absPath)
        return (true, "Moved (copy) " & intent.path & " to " & intent.destPath, @[absPath, absDst])
      except CatchableError as e:
        return (false, "Failed to move: " & e.msg, @[])
  of fokNone:
    discard

# ---------------------------------------------------------------------------
#  Agentic tool loop (built-in HTTP agent)
# ---------------------------------------------------------------------------
# Unlike the deterministic file-op shortcut above, this path gives the LLM real
# function-calling: it can read/list/write/edit files through workspace-sandboxed
# tools and iterate until it produces a final answer. All file access reuses the
# same containment checks (`resolveWorkspacePath` / `isPathInsideWorkspace`) and
# size cap (`MaxFileWriteSize`) as the ACP agent handlers.

const MaxToolResultChars = 60_000  ## Cap tool output fed back to the model.

proc capToolOutput(output: string; context = "tool output"): string =
  ## Truncate tool output so it fits back into the model context. Keeps the
  ## existing truncation pattern consistent across read_file, git_diff, and
  ## search tools.
  if output.len <= MaxToolResultChars:
    return output
  return output[0..<MaxToolResultChars] & "\n... (truncated; " & context & " is " & $output.len & " bytes)"

proc summarizeToolCall(name: string, args: JsonNode): string =
  ## Short human-readable label shown in the thinking area for a tool call.
  let path = args{"path"}.getStr()
  case name
  of "read_file":
    let startLine = args{"start_line"}.getInt(0)
    let endLine = args{"end_line"}.getInt(0)
    if startLine > 0 or endLine > 0:
      "Reading " & path & " (lines " & $startLine & "-" & $endLine & ")"
    else:
      "Reading " & path
  of "list_directory": "Listing " & path
  of "create_directory": "Creating directory " & path
  of "search_text":
    if path.len > 0: "Searching for '" & args{"pattern"}.getStr() & "' in " & path
    else: "Searching for '" & args{"pattern"}.getStr() & "'"
  of "find_files":
    if path.len > 0: "Finding files matching '" & args{"pattern"}.getStr() & "' in " & path
    else: "Finding files matching '" & args{"pattern"}.getStr() & "'"
  of "write_file": "Writing " & path
  of "edit_file": "Editing " & path
  of "git_status": "Checking git status"
  of "git_diff":
    if path.len > 0: "Diffing " & path else: "Reading git diff"
  else:
    if path.len > 0: name & " " & path else: name

proc executeBuiltinTool(t: AIThread, name: string, args: JsonNode,
                        previewMode: bool = false): tuple[content: string, changed: seq[string],
                          needsPreview: bool, previewOld: string, previewNew: string, previewPath: string] =
  ## Execute one built-in tool call inside the workspace sandbox.
  ## When previewMode is true, destructive tools (write_file, edit_file) compute
  ## the result but do NOT write to disk — they set needsPreview=true and
  ## populate previewOld/previewNew so the caller can show a diff before
  ## confirming. When previewMode is false, writes happen immediately (legacy
  ## behavior for ACP agents).
  result = ("", @[], false, "", "", "")
  let path = args{"path"}.getStr()
  case name
  of "read_file":
    if path.len == 0: return ("Error: 'path' is required.", @[], false, "", "", "")
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return ("Error: path is outside the workspace.", @[], false, "", "", "")
    if not fileExists(absPath):
      return ("Error: file not found: " & path, @[], false, "", "", "")
    try:
      var content = readFile(absPath)
      # Line-range support: extract lines start_line..end_line (1-based, inclusive).
      let startLine = args{"start_line"}.getInt(0)
      let endLine = args{"end_line"}.getInt(0)
      if startLine > 0 or endLine > 0:
        let lines = content.splitLines()
        let s = if startLine > 0: startLine.int - 1 else: 0
        let e = if endLine > 0: min(endLine.int, lines.len) else: lines.len
        if s >= lines.len:
          return ("Error: start_line " & $startLine & " exceeds file length (" & $lines.len & " lines).", @[], false, "", "", "")
        content = lines[s..<e].join("\n")
      if content.len > MaxToolResultChars:
        content = content[0..<MaxToolResultChars] &
          "\n... (truncated; file is " & $content.len & " bytes)"
      return (content, @[], false, "", "", "")
    except CatchableError as e:
      return ("Error reading file: " & e.msg, @[], false, "", "", "")

  of "list_directory":
    if path.len == 0: return ("Error: 'path' is required.", @[], false, "", "", "")
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return ("Error: path is outside the workspace.", @[], false, "", "", "")
    if not dirExists(absPath):
      return ("Error: directory not found: " & path, @[], false, "", "", "")
    try:
      var lines: seq[string]
      for kind, entryPath in walkDir(absPath):
        let nm = extractFilename(entryPath)
        case kind
        of pcDir, pcLinkToDir: lines.add(nm & "/")
        else: lines.add(nm)
      if lines.len == 0: return ("(empty directory)", @[], false, "", "", "")
      return (lines.join("\n"), @[], false, "", "", "")
    except CatchableError as e:
      return ("Error listing directory: " & e.msg, @[], false, "", "", "")

  of "create_directory":
    if path.len == 0: return ("Error: 'path' is required.", @[], false, "", "", "")
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return ("Error: path is outside the workspace.", @[], false, "", "", "")
    if dirExists(absPath):
      return ("Directory already exists: " & path, @[], false, "", "", "")
    if fileExists(absPath):
      return ("Error: a file already exists at: " & path, @[], false, "", "", "")
    try:
      createDir(absPath)
      return ("Created directory: " & path, @[absPath], false, "", "", "")
    except CatchableError as e:
      return ("Error creating directory: " & e.msg, @[], false, "", "", "")

  of "write_file":
    if path.len == 0: return ("Error: 'path' is required.", @[], false, "", "", "")
    let content = args{"content"}.getStr()
    if content.len > MaxFileWriteSize:
      return ("Error: content too large (max " & $MaxFileWriteSize & " bytes).", @[], false, "", "", "")
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return ("Error: path is outside the workspace.", @[], false, "", "", "")
    if not previewMode:
      try:
        let parent = absPath.parentDir()
        if parent.len > 0 and not dirExists(parent): createDir(parent)
        writeFile(absPath, content)
        return ("Wrote " & $content.len & " bytes to " & path, @[absPath], false, "", "", "")
      except CatchableError as e:
        return ("Error writing file: " & e.msg, @[], false, "", "", "")
    # Built-in agent path: compute preview, defer the actual write.
    var oldContent = ""
    if fileExists(absPath):
      try:
        oldContent = readFile(absPath)
      except CatchableError:
        discard
    return ("(preview)", @[], true, oldContent, content, absPath)

  of "edit_file":
    if path.len == 0: return ("Error: 'path' is required.", @[], false, "", "", "")
    let oldStr = args{"old_string"}.getStr()
    let newStr = args{"new_string"}.getStr()
    let replaceAll = args{"replace_all"}.getBool(false)
    if oldStr.len == 0:
      return ("Error: 'old_string' must not be empty.", @[], false, "", "", "")
    let absPath = resolveWorkspacePath(path, t.workspaceRoot)
    if not isPathInsideWorkspace(absPath, t.workspaceRoot):
      return ("Error: path is outside the workspace.", @[], false, "", "", "")
    if not fileExists(absPath):
      return ("Error: file not found: " & path, @[], false, "", "", "")
    try:
      let original = readFile(absPath)
      let occurrences = original.count(oldStr)
      if occurrences == 0:
        return ("Error: old_string not found in " & path &
          ". Read the file and match the text exactly.", @[], false, "", "", "")
      if occurrences > 1 and not replaceAll:
        return ("Error: old_string is not unique (" & $occurrences & " matches) in " &
          path & ". Add surrounding context or set replace_all=true.", @[], false, "", "", "")
      let updated = original.replace(oldStr, newStr)
      if updated.len > MaxFileWriteSize:
        return ("Error: resulting file too large (max " & $MaxFileWriteSize & " bytes).", @[], false, "", "", "")
      if not previewMode:
        writeFile(absPath, updated)
        let cnt = if replaceAll: occurrences else: 1
        return ("Edited " & path & " (" & $cnt & " replacement" &
          (if cnt == 1: "" else: "s") & ")", @[absPath], false, "", "", "")
      return ("(preview)", @[], true, original, updated, absPath)
    except CatchableError as e:
      return ("Error editing file: " & e.msg, @[], false, "", "", "")

  of "git_status":
    let repoRoot = gitcmd.getRepoRoot(t.workspaceRoot)
    if repoRoot.len == 0:
      return ("Error: this workspace is not a git repository.", @[], false, "", "", "")
    let branch = gitcmd.getCurrentBranch(repoRoot)
    var lines: seq[string]
    for f in gitcmd.parseGitStatus(repoRoot):
      var parts: seq[string]
      if f.stagedStatus != gfsUnmodified: parts.add("staged")
      if f.workingStatus != gfsUnmodified:
        if f.workingStatus == gfsUntracked: parts.add("new")
        else: parts.add("unstaged")
      if parts.len > 0:
        lines.add("- " & f.path & " (" & parts.join(", ") & ")")
    var outp = "Branch: " & branch & "\n"
    if lines.len == 0: outp.add("No local changes.")
    else: outp.add("Changed files:\n" & lines.join("\n"))
    return (outp, @[], false, "", "", "")

  of "git_diff":
    let repoRoot = gitcmd.getRepoRoot(t.workspaceRoot)
    if repoRoot.len == 0:
      return ("Error: this workspace is not a git repository.", @[], false, "", "", "")
    var diff: string
    if path.len > 0:
      let absPath = resolveWorkspacePath(path, t.workspaceRoot)
      let relPath = relativePath(absPath, repoRoot)
      let staged = gitcmd.getFileDiff(repoRoot, relPath, staged = true)
      let unstaged = gitcmd.getFileDiff(repoRoot, relPath, staged = false)
      diff = staged
      if staged.len > 0 and unstaged.len > 0: diff.add("\n")
      diff.add(unstaged)
    else:
      diff = gitcmd.getAllLocalDiff(repoRoot)
    if diff.strip().len == 0:
      return ("(no local changes)", @[], false, "", "", "")
    if diff.len > MaxToolResultChars:
      diff = diff[0..<MaxToolResultChars] & "\n... (diff truncated)"
    return (diff, @[], false, "", "", "")

  of "search_text":
    let pattern = args{"pattern"}.getStr()
    if pattern.len == 0: return ("Error: 'pattern' is required.", @[], false, "", "", "")
    if findExe("rg").len == 0:
      return ("Error: ripgrep (rg) is not installed; text search is unavailable.", @[], false, "", "", "")
    var relArg = "."
    let subPath = args{"path"}.getStr()
    if subPath.len > 0:
      let absPath = resolveWorkspacePath(subPath, t.workspaceRoot)
      if not isPathInsideWorkspace(absPath, t.workspaceRoot):
        return ("Error: path is outside the workspace.", @[], false, "", "", "")
      relArg = quoteShell(subPath)
    let caseSensitive = args{"case_sensitive"}.getBool(false)
    let isRegex = args{"is_regex"}.getBool(false)
    var cmd = "rg -n --no-heading --color never"
    if not caseSensitive: cmd &= " -i"
    if not isRegex: cmd &= " -F"
    cmd &= " -- " & quoteShell(pattern) & " " & relArg
    try:
      let (output, _) = execCmdEx(cmd, workingDir = t.workspaceRoot)
      if output.strip().len == 0:
        return ("(no matches)", @[], false, "", "", "")
      return (capToolOutput(output), @[], false, "", "", "")
    except CatchableError as e:
      return ("Error running search: " & e.msg, @[], false, "", "", "")

  of "find_files":
    let pattern = args{"pattern"}.getStr()
    if pattern.len == 0: return ("Error: 'pattern' is required.", @[], false, "", "", "")
    if findExe("rg").len == 0:
      return ("Error: ripgrep (rg) is not installed; file search is unavailable.", @[], false, "", "", "")
    var relArg = "."
    let subPath = args{"path"}.getStr()
    if subPath.len > 0:
      let absPath = resolveWorkspacePath(subPath, t.workspaceRoot)
      if not isPathInsideWorkspace(absPath, t.workspaceRoot):
        return ("Error: path is outside the workspace.", @[], false, "", "", "")
      relArg = quoteShell(subPath)
    let cmd = "rg --files -g " & quoteShell(pattern) & " " & relArg
    try:
      let (output, _) = execCmdEx(cmd, workingDir = t.workspaceRoot)
      if output.strip().len == 0:
        return ("(no files matched)", @[], false, "", "", "")
      return (capToolOutput(output), @[], false, "", "", "")
    except CatchableError as e:
      return ("Error finding files: " & e.msg, @[], false, "", "", "")

  else:
    return ("Error: unknown tool '" & name & "'.", @[], false, "", "", "")

proc checkCancelled(t: AIThread): bool =
  ## Non-blocking check for amkCancel or shutdown. Drains a pending cancel from
  ## reqChan and returns true if the agentic loop should stop. Keeps the same
  ## semantics as waitForEditConfirmation.
  if t.shuttingDown.load(moAcquire) or t.reqChan.isClosed:
    return true
  var msg: AIMessage
  if channel_spsc.tryReceive(t.reqChan, msg):
    case msg.kind
    of amkShutdown, amkCancel:
      return true
    of amkEditConfirm:
      # Should not arrive here; swallow to avoid confusing the main loop.
      return false
    else:
      # Other request (new message, etc.): let the main loop handle it.
      return false
  return false

proc waitForEditConfirmation(t: AIThread): bool =
  ## Check if a pending confirmation has arrived on reqChan.
  ## Returns true if user accepted or no confirm mechanism is active yet
  ## (auto-accept — the UI will display the diff in the preview message).
  ## When the UI eventually sends amkEditConfirm, we honor it.
  while true:
    if t.shuttingDown.load(moAcquire) or t.reqChan.isClosed:
      return false
    var msg: AIMessage
    if channel_spsc.tryReceive(t.reqChan, msg):
      case msg.kind
      of amkEditConfirm:
        return msg.text == "ok"
      of amkShutdown, amkCancel:
        return false
      else:
        # Unexpected message while waiting for confirm — buffer is shared with
        # the main runBuiltinAI loop. If it's a new user message or other
        # request, bail out so the main loop can process it.
        return false
    else:
      # No confirm message waiting yet — auto-accept to avoid hanging.
      # The diff was already sent via amkEditPreview so the UI can display it.
      return true

proc runBuiltinAgentic(t: AIThread, userText: string) =
  ## Agentic tool loop: the model can call read/list/write/edit tools to inspect
  ## and modify workspace files directly, iterating until it returns a final
  ## text answer. Only the final answer is persisted to conversation history.
  let (provider, model) = resolveBuiltinModel(t.config, userText)
  if provider.len == 0 or model.len == 0:
    t.sendResponse(AIMessage(kind: amkError, error: "Model disabled"))
    return

  var systemPrompt =
    "You are the AI assistant embedded in the Drift code editor. You operate " &
    "directly inside the user's workspace at " & t.workspaceRoot & ".\n\n" &
    "You can read, list, create and edit files using the provided tools, and " &
    "inspect local version-control changes with git_status and git_diff. When " &
    "the user asks to review, summarize, or look at their changes, call " &
    "git_status and git_diff to see the actual diff before answering. When the " &
    "user asks for a change, MAKE the change yourself by calling the tools — do " &
    "not merely describe what to do or print code for the user to paste. Always " &
    "read a file before editing it so your edits match exactly. Use edit_file " &
    "for targeted changes and write_file for new files or full rewrites. Keep " &
    "changes minimal and focused. When finished, briefly summarize what you did."
  if t.planMode:
    systemPrompt = PlanModePrompt &
      "\n\n(You may use the read-only tools to inspect the code while planning. " &
      "Do not attempt to modify files.)"
  let projectContext = loadProjectContext(t.workspaceRoot)
  if projectContext.len > 0:
    systemPrompt.add("\n\n" & projectContext)

  # Canonical (OpenAI-format) message array driven through the loop.
  var messages = newJArray()
  messages.add(%*{"role": "system", "content": systemPrompt})
  for turn in t.history:
    messages.add(%*{"role": turn.role, "content": turn.content})
  messages.add(%*{"role": "user", "content": userText})

  var finalText = ""
  var errored = false
  var cancelled = false
  var iterations = 0
  while iterations < MaxAgenticIterations:
    inc iterations
    # Honour Stop/shutdown requested mid-run, before spending another API call.
    if t.checkCancelled():
      cancelled = true
      break
    let effort = if providerSupportsThinking(provider): t.config.aiReasoningEffort else: ""
    let res = doAgenticChat(t.config, provider, model, messages, t.planMode, effort)
    if res.error.len > 0:
      t.sendResponse(AIMessage(kind: amkError, error: res.error))
      errored = true
      break
    # Surface the model's chain-of-thought (DeepSeek reasoning_content) as
    # thinking, whether or not this turn ends in tool calls.
    if res.reasoning.strip().len > 0:
      t.sendResponse(AIMessage(kind: amkThinking, text: res.reasoning))
    if res.toolCalls.len == 0:
      finalText = res.content
      break
    # Surface any interim assistant text as thinking, then run the tools.
    if res.content.strip().len > 0:
      t.sendResponse(AIMessage(kind: amkThinking, text: res.content))
    messages.add(assistantTurnJson(res))
    for tc in res.toolCalls:
      # Stop promptly between tools rather than running the whole batch.
      if t.checkCancelled():
        cancelled = true
        break
      t.sendResponse(AIMessage(kind: amkThinking, text: summarizeToolCall(tc.name, tc.arguments)))
      # Pass previewMode=true so destructive tools compute but don't write yet.
      let (toolContent, changed, needsPreview, prevOld, prevNew, prevPath) =
        executeBuiltinTool(t, tc.name, tc.arguments, previewMode = true)
      if needsPreview:
        # Send preview to UI and wait for confirmation.
        let summary = case tc.name
          of "write_file":
            if prevOld.len == 0: "Create " & prevPath
            else: "Rewrite " & prevPath
          else: "Edit " & prevPath
        t.sendResponse(AIMessage(
          kind: amkEditPreview,
          previewPath: prevPath,
          previewOld: prevOld,
          previewNew: prevNew,
          previewSummary: summary
        ))
        if waitForEditConfirmation(t):
          # User accepted: apply the write now.
          try:
            let parent = prevPath.parentDir()
            if parent.len > 0 and not dirExists(parent): createDir(parent)
            writeFile(prevPath, prevNew)
            let bytes = prevNew.len
            let label = if prevOld.len == 0: "Created " else: "Wrote "
            let msg = label & prevPath & " (" & $bytes & " bytes)"
            for cp in @[prevPath]:
              t.sendResponse(AIMessage(kind: amkFileChanged, text: cp))
            messages.add(%*{"role": "tool", "tool_call_id": tc.id, "content": msg})
          except CatchableError as e:
            messages.add(%*{"role": "tool", "tool_call_id": tc.id,
              "content": "Error writing file: " & e.msg})
        else:
          # User rejected the edit.
          messages.add(%*{"role": "tool", "tool_call_id": tc.id,
            "content": "Edit was rejected by the user. Do not retry this exact edit. Explain what alternative you can offer."})
      else:
        for cp in changed:
          t.sendResponse(AIMessage(kind: amkFileChanged, text: cp))
        messages.add(%*{"role": "tool", "tool_call_id": tc.id, "content": toolContent})
    if cancelled:
      break

  if errored:
    return
  if cancelled:
    # Reset the UI's streaming state without persisting a partial turn.
    t.sendResponse(AIMessage(kind: amkResponseDone))
    return
  if finalText.len == 0:
    finalText = "Reached the tool-call limit (" & $MaxAgenticIterations &
      ") without a final answer."
  t.sendResponse(AIMessage(kind: amkResponseChunk, text: finalText))
  t.sendResponse(AIMessage(kind: amkResponseDone))
  t.history.add((role: ChatRoleUser, content: userText))
  t.history.add((role: ChatRoleAssistant, content: finalText))
  while t.history.len > MaxHistoryTurns * 2:
    t.history.delete(0)

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
      # --- Direct file-operation execution (no LLM needed) ---
      # Check for clear imperative file commands (delete/create/move) first.
      # These are executed directly and skip the LLM call entirely.
      let fileOp = detectFileOp(req.text)
      if fileOp.kind != fokNone:
        let (_, msg, paths) = executeFileOp(t, fileOp)
        # Notify the UI of changed paths so file explorer & buffers refresh.
        for p in paths:
          t.sendResponse(AIMessage(kind: amkFileChanged, text: p))
        t.sendResponse(AIMessage(kind: amkResponseChunk, text: msg))
        t.sendResponse(AIMessage(kind: amkResponseDone))
        # Record into conversation history for multi-turn memory.
        t.history.add((role: ChatRoleUser, content: req.text))
        t.history.add((role: ChatRoleAssistant, content: msg))
        while t.history.len > MaxHistoryTurns * 2:
          t.history.delete(0)
      else:
        # Detect git-related intent once. If the user is asking about local
        # changes, attach status + diff and treat the reply specially (commit
        # message / diff-grounded answer). This flow does not use tools.
        let isGitIntent = classifyGitIntent(t.config, req.text)
        var gitContext = ""
        if isGitIntent:
          gitContext = buildGitContextPrompt(t.workspaceRoot, req.text)

        if isGitIntent and gitContext.len > 0:
          var promptText = gitContext
          if t.planMode:
            promptText = PlanModePrompt & "\n\n## User Request\n\n" & promptText
          let answer = doChatCompletionHistory(t.config, promptText, t.history)
          if answer.startsWith("HTTP error") or answer.startsWith("Request failed") or
             answer.startsWith("Unexpected response") or answer.startsWith("Model disabled"):
            t.sendResponse(AIMessage(kind: amkError, error: answer))
          else:
            t.history.add((role: ChatRoleUser, content: req.text))
            t.history.add((role: ChatRoleAssistant, content: answer))
            while t.history.len > MaxHistoryTurns * 2:
              t.history.delete(0)
            # Agent-like execution: treat the model output as the commit message,
            # stage all changes, commit, and report the result.
            var finalText = answer
            let message = answer.strip()
            if message.len > 0:
              if gitcmd.stageAllChanges(t.workspaceRoot) and gitcmd.commitChanges(t.workspaceRoot, message):
                finalText = "Committed with message:\n\n" & message
              else:
                finalText = "Generated commit message:\n\n" & message & "\n\n(commit failed)"
            t.sendResponse(AIMessage(kind: amkResponseChunk, text: finalText))
            t.sendResponse(AIMessage(kind: amkResponseDone))
        else:
          # General request: run the agentic tool loop so the model can read and
          # modify workspace files directly instead of only advising.
          runBuiltinAgentic(t, req.text)
    of amkNewSession, amkClearSession:
      # Start a fresh conversation: clear multi-turn history.
      t.history.setLen(0)
    of amkTogglePlanMode:
      t.planMode = not t.planMode
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

proc togglePlanMode*(t: AIThread) =
  sendOrWarn(t.reqChan, AIMessage(kind: amkTogglePlanMode), "togglePlanMode")

proc confirmEdit*(t: AIThread, accepted: bool) =
  ## Send confirmation back to the AI thread for a pending edit preview.
  sendOrWarn(t.reqChan, AIMessage(kind: amkEditConfirm,
    text: if accepted: "ok" else: "reject"), "confirmEdit")

proc shutdown*(t: AIThread) =
  if t.shuttingDown.exchange(true, moAcquire):
    return
  sendOrWarn(t.reqChan, AIMessage(kind: amkShutdown), "shutdown")
  t.respChan.close()
  t.reqChan.close()

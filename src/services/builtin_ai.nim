## Built-in HTTP AI agent helpers
## Talks to OpenAI-compatible chat completions endpoints for model providers.
## The caller (ai_thread.nim) runs this in its own worker thread.

import std/[httpclient, json, os, strutils, uri]
import ../core/config
import ../services/git as gitcmd
import prompt_complexity

const
  HttpTimeoutMs* = 60_000   ## Per-request timeout for built-in HTTP calls.
  HttpMaxRetries = 3        ## Max retry count for transient HTTP failures.
  HttpRetryBaseMs = 500     ## Base backoff (ms) before first retry.
  ChatRoleUser* = "user"
  ChatRoleAssistant* = "assistant"
  MaxContextFileSize* = 16_384  ## Max bytes to read from project context files (16KB).

type
  BuiltinModelProvider* = object
    id*: string
    label*: string
    baseUrl*: string
    models*: seq[string]

  ChatTurn* = tuple[role: string, content: string]

proc loadProjectContext*(workspaceRoot: string): string =
  ## Load project context files (AGENTS.md, CLAUDE.md) for the builtin agent.
  ## These files provide coding conventions, build commands, and project rules.
  ## Returns concatenated content of found files, or empty string.
  if workspaceRoot.len == 0:
    return ""

  result = ""
  let contextFiles = ["AGENTS.md", "CLAUDE.md"]

  for fileName in contextFiles:
    let filePath = workspaceRoot / fileName
    if fileExists(filePath):
      try:
        let content = readFile(filePath)
        if content.len > 0:
          # Truncate if too large to avoid overwhelming the context window.
          let truncated = if content.len > MaxContextFileSize:
            content[0..<MaxContextFileSize] & "\n... (truncated)"
          else:
            content
          result.add("## Project Context (" & fileName & ")\n\n")
          result.add(truncated)
          result.add("\n\n")
          # Only load the first found file to keep context focused.
          break
      except CatchableError:
        discard

const BuiltinModelProviders* = [
  BuiltinModelProvider(
    id: "openai",
    label: "OpenAI",
    baseUrl: "https://api.openai.com/v1",
    models: @["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "o3", "o4-mini"]
  ),
  BuiltinModelProvider(
    id: "deepseek",
    label: "DeepSeek",
    baseUrl: "https://api.deepseek.com",
    models: @["deepseek-v4-flash", "deepseek-v4-pro"]
  ),
  BuiltinModelProvider(
    id: "anthropic",
    label: "Anthropic",
    baseUrl: "https://api.anthropic.com/v1",
    models: @["claude-sonnet-4-6", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-haiku-4-5"]
  ),
  BuiltinModelProvider(
    id: "moonshot",
    label: "Moonshot",
    baseUrl: "https://api.moonshot.cn/v1",
    models: @["kimi-for-coding"]
  ),
  BuiltinModelProvider(
    id: "google",
    label: "Google Gemini",
    baseUrl: "https://generativelanguage.googleapis.com/v1beta",
    models: @["gemini-3.5-flash", "gemini-3.1-pro", "gemini-3.1-flash-lite"]
  ),
  BuiltinModelProvider(
    id: "zhipu",
    label: "Zhipu GLM",
    baseUrl: "https://open.bigmodel.cn/api/paas/v4",
    models: @["glm-5", "glm-4-plus", "glm-4-flash"]
  ),
  BuiltinModelProvider(
    id: "minimax",
    label: "MiniMax",
    baseUrl: "https://api.minimaxi.com/v1",
    models: @["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.7-highspeed"]
  ),
  BuiltinModelProvider(
    id: "openrouter",
    label: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    models: @["anthropic/claude-sonnet-4", "meta-llama/llama-4-maverick"]
  ),
]

proc defaultBaseUrl*(providerId: string): string =
  let p = providerId.toLowerAscii()
  for mp in BuiltinModelProviders:
    if mp.id == p:
      return mp.baseUrl
  return ""

proc providerLabel*(providerId: string): string =
  let p = providerId.toLowerAscii()
  for mp in BuiltinModelProviders:
    if mp.id == p:
      return mp.label
  return p.capitalizeAscii()

proc isHttpAgent*(agentId: string): bool =
  ## Only the built-in agent speaks HTTP directly; everything else uses ACP.
  agentId.toLowerAscii() == "builtin"

proc allBuiltinModels*(config: AppConfig): seq[tuple[providerId, model, label: string]] =
  ## Flat list of every built-in model with a display label, optionally filtered
  ## to models the user has enabled.
  for mp in BuiltinModelProviders:
    for m in mp.models:
      if isBuiltinModelEnabled(config, mp.id, m):
        result.add((mp.id, m, mp.label & " — " & m))

proc allBuiltinModels*(): seq[tuple[providerId, model, label: string]] =
  ## Flat list of every built-in model (convenience overload when no config is
  ## in scope; all models are treated as enabled).
  for mp in BuiltinModelProviders:
    for m in mp.models:
      result.add((mp.id, m, mp.label & " — " & m))

proc isAnthropicProvider*(providerId: string): bool =
  ## Check if provider uses Anthropic API format (not OpenAI-compatible).
  providerId.toLowerAscii() == "anthropic"

proc providerSupportsThinking*(providerId: string): bool =
  ## Whether the provider exposes an explicit reasoning/thinking-mode toggle on
  ## its OpenAI-compatible chat API. DeepSeek accepts a ``thinking`` object and
  ## returns the chain-of-thought in ``message.reasoning_content``.
  providerId.toLowerAscii() == "deepseek"

proc reasoningVariants*(providerId: string): seq[string] =
  ## User-selectable thinking-effort variants for a provider, least-to-most
  ## capable. Empty when the provider has no thinking mode. These differ per
  ## provider (DeepSeek: high/max; OpenAI: minimal/low/medium/high; Anthropic:
  ## token budgets), so this is the single source of truth for the menu and for
  ## request-body validation — extend the cases as more providers are wired.
  case providerId.toLowerAscii()
  of "deepseek": @["high", "max"]
  else: @[]

proc applyThinking*(body: JsonNode; providerId: string; effort: string = "high") =
  ## Enable DeepSeek-style thinking mode on an OpenAI-format request body and set
  ## the reasoning-effort variant. No-op for providers without a thinking toggle,
  ## so other providers' bodies are left untouched. Mutates ``body`` in place.
  if body == nil or body.kind != JObject: return
  if not providerSupportsThinking(providerId): return
  body["thinking"] = %*{"type": "enabled"}
  let e = effort.toLowerAscii()
  if e in reasoningVariants(providerId):
    body["reasoning_effort"] = %e

proc newChatClient(config: AppConfig, providerId: string = ""): HttpClient =
  ## Create a shared HTTP client with auth headers for chat completions.
  result = newHttpClient(userAgent = "drift/1.0", timeout = HttpTimeoutMs)
  result.headers = newHttpHeaders({
    "Content-Type": "application/json"
  })
  if config.aiApiKey.len > 0:
    if isAnthropicProvider(providerId):
      result.headers["x-api-key"] = config.aiApiKey
      result.headers["anthropic-version"] = "2023-06-01"
    else:
      result.headers["Authorization"] = "Bearer " & config.aiApiKey

proc parseChatResult(resp: Response): string =
  ## Parse an OpenAI-compatible chat completion response body.
  ## Returns the assistant message content, or an empty string on failure.
  let j = parseJson(resp.body)
  if j.hasKey("choices") and j["choices"].kind == JArray and j["choices"].len > 0:
    let choice = j["choices"][0]
    if choice.hasKey("message") and choice["message"].hasKey("content"):
      return choice["message"]["content"].getStr()
  return ""

proc parseAnthropicResult(resp: Response): string =
  ## Parse Anthropic Messages API response body.
  ## Returns the assistant message content, or an empty string on failure.
  ## Handles multiple content blocks by concatenating text blocks.
  let j = parseJson(resp.body)
  if j.hasKey("content") and j["content"].kind == JArray and j["content"].len > 0:
    var parts: seq[string]
    for contentItem in j["content"]:
      if contentItem.kind == JObject and contentItem.hasKey("type") and contentItem.hasKey("text"):
        if contentItem["type"].getStr() == "text":
          parts.add(contentItem["text"].getStr())
    if parts.len > 0:
      return parts.join("\n")
  return ""

proc buildAnthropicRequest*(config: AppConfig, prompt: string): string =
  ## Build Anthropic Messages API request body (single-turn).
  let (_, model) = resolveBuiltinModel(config, prompt)
  let body = %*{
    "model": model,
    "max_tokens": 4096,
    "messages": [{"role": "user", "content": prompt}]
  }
  return $body

proc buildAnthropicRequestHistory*(config: AppConfig, prompt: string,
                                   history: seq[ChatTurn]): string =
  ## Build Anthropic Messages API request body with multi-turn history.
  let (_, model) = resolveBuiltinModel(config, prompt)
  var messages = newJArray()
  for turn in history:
    messages.add(%*{"role": turn.role, "content": turn.content})
  messages.add(%*{"role": "user", "content": prompt})
  let body = %*{
    "model": model,
    "max_tokens": 4096,
    "messages": messages
  }
  return $body

proc isTransientHttpError(code: int): bool =
  ## True for status codes worth retrying (429 rate-limit, 5xx server errors).
  code == 429 or (code >= 500 and code <= 599)

proc retryableRequest(client: HttpClient, url, body: string): Response =
  ## HTTP POST with exponential backoff retry on transient failures.
  var delay = HttpRetryBaseMs
  for attempt in 1..HttpMaxRetries:
    try:
      result = client.request(url, httpMethod = HttpPost, body = body)
      if not isTransientHttpError(result.code.int):
        return
    except CatchableError:
      discard
    sleep(delay)
    delay *= 2
  try:
    result = client.request(url, httpMethod = HttpPost, body = body)
  except CatchableError as e:
    raise e

proc makeChatRequest*(config: AppConfig, prompt: string): string =
  ## Build OpenAI-compatible /chat/completions request body (single-turn, kept
  ## for backward compatibility/tests).
  let (_, model) = resolveBuiltinModel(config, prompt)
  let messages = %*[{"role": "user", "content": prompt}]
  let body = %*{
    "model": model,
    "messages": messages,
    "stream": false
  }
  return $body

proc makeChatRequestHistory*(config: AppConfig, prompt: string,
                             history: seq[ChatTurn]): string =
  ## Build OpenAI-compatible /chat/completions request body with multi-turn
  ## conversation history. ``history`` carries prior user/assistant turns
  ## (most-recent-last); the new user prompt is appended as the final message.
  let (_, model) = resolveBuiltinModel(config, prompt)
  var messages = newJArray()
  for turn in history:
    messages.add(%*{"role": turn.role, "content": turn.content})
  messages.add(%*{"role": "user", "content": prompt})
  let body = %*{
    "model": model,
    "messages": messages,
    "stream": false
  }
  return $body

proc doChatCompletionWithModel*(config: AppConfig, prompt, providerId, model: string): string =
  ## Synchronous HTTP call to a specific provider/model (single-turn).
  ## Returns the assistant message content, or an error string starting with
  ## "HTTP error", "Request failed", "Unexpected response", or "Model disabled".
  if not isBuiltinModelEnabled(config, providerId, model):
    return "Model disabled: " & providerId & "/" & model
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let client = newChatClient(config, providerId)

  var url: string
  var body: string
  if isAnthropicProvider(providerId):
    url = baseUrl & "/messages"
    body = $ %*{
      "model": model,
      "max_tokens": 4096,
      "messages": [{"role": "user", "content": prompt}]
    }
  else:
    url = baseUrl & "/chat/completions"
    body = $ %*{
      "model": model,
      "messages": [{"role": "user", "content": prompt}],
      "stream": false
    }

  try:
    let resp = retryableRequest(client, url, body)
    if resp.code.int div 100 != 2:
      return "HTTP error " & $resp.code & ": " & resp.body
    let parsed = if isAnthropicProvider(providerId):
      parseAnthropicResult(resp)
    else:
      parseChatResult(resp)
    if parsed.len > 0:
      return parsed
    return "Unexpected response: " & resp.body
  except CatchableError as e:
    return "Request failed: " & e.msg
  finally:
    client.close()

proc classifyGitIntent*(config: AppConfig, userText: string): bool =
  ## Ask the lightweight model whether the user is requesting git-related help.
  ## Falls back to false on any error so we don't block the main prompt.
  ## Uses a keyword pre-filter to skip the LLM call for clearly non-git prompts.
  let lower = userText.toLowerAscii()
  var hasGitKeyword = false
  for kw in ["commit", "diff", "stage", "unstaged", "stash", "git status",
              "git log", "git branch", "merge", "rebase", "checkout",
              "git add", "git rm", "working tree", "repo", "repository"]:
    if lower.contains(kw):
      hasGitKeyword = true
      break
  if not hasGitKeyword:
    return false
  let classifierPrompt = """You are a classifier. Read the user message and decide if it is asking about git changes, commit messages, diffs, or code review of local modifications.

Respond with exactly one word: YES or NO.

User message: """ & userText & "\n\nAnswer:"
  let provider = config.aiLightweightModelProvider
  let model = config.aiLightweightModel
  if provider.len == 0 or model.len == 0 or not isBuiltinModelEnabled(config, provider, model):
    return false
  let answer = doChatCompletionWithModel(config, classifierPrompt, provider, model).strip().toLowerAscii()
  return answer.startsWith("yes")

proc buildGitContextPrompt*(repoRoot, userText: string): string =
  ## Build a prompt that includes local git status + diff for the builtin agent.
  ## Returns "" if there is no git repo or no local changes.
  let root = if repoRoot.len > 0: repoRoot else: getCurrentDir()
  if not gitcmd.isGitRepository(root):
    return ""

  let allStatus = gitcmd.parseGitStatus(root)
  var stagedFiles, unstagedFiles: seq[GitFileChange]
  for f in allStatus:
    if f.stagedStatus != gfsUnmodified:
      stagedFiles.add(f)
    if f.workingStatus != gfsUnmodified:
      unstagedFiles.add(f)

  if stagedFiles.len == 0 and unstagedFiles.len == 0:
    return ""

  var allFiles = stagedFiles
  for u in unstagedFiles:
    var found = false
    for a in allFiles:
      if a.path == u.path:
        found = true
        break
    if not found: allFiles.add(u)

  var fileList = ""
  for f in allFiles:
    var parts: seq[string]
    if f.stagedStatus != gfsUnmodified:
      parts.add("staged")
    if f.workingStatus != gfsUnmodified:
      if f.workingStatus == gfsUntracked:
        parts.add("new")
      else:
        parts.add("unstaged")
    fileList.add("- " & f.path & " (" & parts.join(", ") & ")\n")

  let branch = gitcmd.getCurrentBranch(root)
  let diff = gitcmd.getAllLocalDiff(root)

  result = "You are the AI assistant inside the Drift editor. The user is asking about local git changes.\n\n"
  result.add("Repository: " & root & "\n")
  result.add("Branch: " & branch & "\n\n")
  result.add("Changed files:\n" & fileList & "\n")
  result.add("Working tree diff:\n```diff\n" & diff & "\n```\n\n")
  result.add("User request: " & userText & "\n\n")
  result.add("If the user wants a commit message, respond ONLY with the commit message text (conventional commit style: type[scope]: summary). Otherwise answer their question using the diff above. Do not say you cannot access files or git data.\n")

proc doChatCompletion*(config: AppConfig, prompt: string): string =
  ## Synchronous HTTP call to the configured endpoint (single-turn).
  ## Returns the assistant message content, or an error string starting with
  ## "HTTP error", "Request failed", "Unexpected response", or "Model disabled".
  let (providerId, model) = resolveBuiltinModel(config, prompt)
  if providerId.len == 0 or model.len == 0:
    return "Model disabled"
  if not isBuiltinModelEnabled(config, providerId, model):
    return "Model disabled: " & providerId & "/" & model
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let client = newChatClient(config, providerId)

  var url: string
  var body: string
  if isAnthropicProvider(providerId):
    url = baseUrl & "/messages"
    body = buildAnthropicRequest(config, prompt)
  else:
    url = baseUrl & "/chat/completions"
    body = makeChatRequest(config, prompt)

  try:
    let resp = retryableRequest(client, url, body)
    if resp.code.int div 100 != 2:
      return "HTTP error " & $resp.code & ": " & resp.body
    let parsed = if isAnthropicProvider(providerId):
      parseAnthropicResult(resp)
    else:
      parseChatResult(resp)
    if parsed.len > 0:
      return parsed
    return "Unexpected response: " & resp.body
  except CatchableError as e:
    return "Request failed: " & e.msg
  finally:
    client.close()

proc doChatCompletionHistory*(config: AppConfig, prompt: string,
                              history: seq[ChatTurn]): string =
  ## Synchronous HTTP call to the configured endpoint with multi-turn history.
  ## Returns the assistant message content, or an error string starting with
  ## "HTTP error", "Request failed", "Unexpected response", or "Model disabled".
  let (providerId, model) = resolveBuiltinModel(config, prompt)
  if providerId.len == 0 or model.len == 0:
    return "Model disabled"
  if not isBuiltinModelEnabled(config, providerId, model):
    return "Model disabled: " & providerId & "/" & model
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let client = newChatClient(config, providerId)

  var url: string
  var body: string
  if isAnthropicProvider(providerId):
    url = baseUrl & "/messages"
    body = buildAnthropicRequestHistory(config, prompt, history)
  else:
    url = baseUrl & "/chat/completions"
    body = makeChatRequestHistory(config, prompt, history)

  try:
    let resp = retryableRequest(client, url, body)
    if resp.code.int div 100 != 2:
      return "HTTP error " & $resp.code & ": " & resp.body
    let parsed = if isAnthropicProvider(providerId):
      parseAnthropicResult(resp)
    else:
      parseChatResult(resp)
    if parsed.len > 0:
      return parsed
    return "Unexpected response: " & resp.body
  except CatchableError as e:
    return "Request failed: " & e.msg
  finally:
    client.close()

# ---------------------------------------------------------------------------
#  Tool-calling (function-calling) support for the built-in HTTP agent
# ---------------------------------------------------------------------------
# Lets the built-in agent actually read and modify workspace files instead of
# only returning instructions. Supports both OpenAI-compatible
# /chat/completions function-calling and the Anthropic Messages tool-use API.
# The caller (ai_thread.nim) drives the agentic loop: send the conversation +
# tool schemas, execute any requested tool calls, feed the results back, and
# repeat until the model returns a final text answer.

type
  AIToolCall* = object
    id*: string          ## Provider-assigned call id, echoed back with the result.
    name*: string        ## Tool/function name.
    arguments*: JsonNode ## Parsed arguments object (never nil; {} when absent).

  AgenticResult* = object
    content*: string          ## Assistant text (may be empty when tools are called).
    reasoning*: string        ## Chain-of-thought (DeepSeek ``reasoning_content``); empty if none.
    toolCalls*: seq[AIToolCall]
    error*: string            ## Non-empty on HTTP/transport/parse failure.

proc builtinToolDefs(planMode: bool): seq[tuple[name, description: string, parameters: JsonNode]] =
  ## Neutral tool definitions. In plan mode only the read-only tools are offered
  ## so the model can inspect the code while planning but cannot mutate files.
  result = @[
    ("read_file", "Read the contents of a text file in the workspace. Optionally specify start_line and end_line (1-based, inclusive) to read a specific range.",
      %*{"type": "object",
         "properties": {
           "path": {"type": "string", "description": "File path relative to the workspace root (or absolute inside it)."},
           "start_line": {"type": "integer", "description": "Optional 1-based start line. Omit to read from the beginning."},
           "end_line": {"type": "integer", "description": "Optional 1-based end line (inclusive). Omit to read to the end."}
         },
         "required": ["path"]}),
    ("list_directory", "List the files and subdirectories of a directory in the workspace.",
      %*{"type": "object",
         "properties": {"path": {"type": "string", "description": "Directory path relative to the workspace root."}},
         "required": ["path"]}),
    ("search_text", "Search file contents across the workspace for a string or regex (like grep/ripgrep). Returns matching lines as `path:line:text`. Use this to find where a symbol is defined or all the places it is used, instead of opening files one by one.",
      %*{"type": "object",
         "properties": {
           "pattern": {"type": "string", "description": "Text or regular expression to search for."},
           "path": {"type": "string", "description": "Optional subdirectory or file to limit the search to (relative to the workspace root)."},
           "is_regex": {"type": "boolean", "description": "Treat the pattern as a regular expression. Default false (literal string)."},
           "case_sensitive": {"type": "boolean", "description": "Case-sensitive match. Default false."}
         },
         "required": ["pattern"]}),
    ("find_files", "Find files by name or glob pattern across the workspace (e.g. \"*.nim\", \"src/**/*.ts\", \"test_*\"). Returns matching file paths. Use this to locate a file when you don't know its exact path.",
      %*{"type": "object",
         "properties": {
           "pattern": {"type": "string", "description": "Glob pattern to match file paths, e.g. \"*.nim\" or \"src/**/*.ts\"."},
           "path": {"type": "string", "description": "Optional subdirectory to search under (relative to the workspace root)."}
         },
         "required": ["pattern"]}),
    ("git_status", "Show the current git branch and the list of locally changed files (staged, unstaged, untracked). Use this when the user asks to review, summarize, or look at their changes.",
      %*{"type": "object", "properties": {}}),
    ("git_diff", "Show the git diff of local changes. Pass a file path for that file's diff, or omit it for the full working-tree diff.",
      %*{"type": "object",
         "properties": {"path": {"type": "string", "description": "Optional file path relative to the workspace root. Omit for the whole working tree."}}}),
  ]
  if planMode:
    return
  result.add(("create_directory",
    "Create a directory (and any missing parent directories) at the given path.",
    %*{"type": "object",
       "properties": {
         "path": {"type": "string", "description": "Directory path relative to the workspace root (or absolute inside it)."}
       },
       "required": ["path"]}))
  result.add(("write_file",
    "Create a new file or completely overwrite an existing file with the given content.",
    %*{"type": "object",
       "properties": {
         "path": {"type": "string", "description": "File path relative to the workspace root."},
         "content": {"type": "string", "description": "Full file content to write."}},
       "required": ["path", "content"]}))
  result.add(("edit_file",
    "Replace an exact substring in an existing file. Read the file first so old_string matches exactly (including whitespace and indentation). old_string must be unique in the file unless replace_all is true.",
    %*{"type": "object",
       "properties": {
         "path": {"type": "string", "description": "File path relative to the workspace root."},
         "old_string": {"type": "string", "description": "Exact text to find and replace."},
         "new_string": {"type": "string", "description": "Replacement text."},
         "replace_all": {"type": "boolean", "description": "Replace every occurrence instead of requiring a unique match. Default false."}},
       "required": ["path", "old_string", "new_string"]}))

proc toOpenAITools(defs: seq[tuple[name, description: string, parameters: JsonNode]]): JsonNode =
  result = newJArray()
  for d in defs:
    result.add(%*{
      "type": "function",
      "function": {"name": d.name, "description": d.description, "parameters": d.parameters}
    })

proc toAnthropicTools(defs: seq[tuple[name, description: string, parameters: JsonNode]]): JsonNode =
  result = newJArray()
  for d in defs:
    result.add(%*{"name": d.name, "description": d.description, "input_schema": d.parameters})

proc assistantTurnJson*(res: AgenticResult): JsonNode =
  ## Build a canonical (OpenAI-format) assistant message from an AgenticResult,
  ## suitable for appending to the running message array before the tool results.
  result = %*{"role": "assistant", "content": res.content}
  if res.toolCalls.len > 0:
    # DeepSeek thinking mode rejects (HTTP 400) any tool-call follow-up whose
    # assistant message omits reasoning_content, so always echo it back on
    # tool-call turns. Other OpenAI-compatible providers ignore the extra field.
    result["reasoning_content"] = %res.reasoning
    var arr = newJArray()
    for tc in res.toolCalls:
      arr.add(%*{
        "id": tc.id,
        "type": "function",
        "function": {"name": tc.name, "arguments": $tc.arguments}
      })
    result["tool_calls"] = arr
  elif res.reasoning.len > 0:
    result["reasoning_content"] = %res.reasoning

proc toAnthropicMessages(messages: JsonNode): tuple[system: string, msgs: JsonNode] =
  ## Convert canonical OpenAI-format messages into the Anthropic Messages shape:
  ## system messages are hoisted into the top-level system string, assistant
  ## tool_calls become tool_use content blocks, and consecutive tool results are
  ## merged into a single user turn of tool_result blocks.
  var sys = ""
  var arr = newJArray()
  var i = 0
  let n = messages.len
  while i < n:
    let m = messages[i]
    let role = m{"role"}.getStr()
    case role
    of "system":
      if sys.len > 0: sys.add("\n\n")
      sys.add(m{"content"}.getStr())
      inc i
    of "user":
      arr.add(%*{"role": "user", "content": m{"content"}.getStr()})
      inc i
    of "assistant":
      var blocks = newJArray()
      let c = m{"content"}
      if c != nil and c.kind == JString and c.getStr().len > 0:
        blocks.add(%*{"type": "text", "text": c.getStr()})
      if m.hasKey("tool_calls") and m["tool_calls"].kind == JArray:
        for tc in m["tool_calls"]:
          let fn = tc{"function"}
          if fn == nil: continue
          var input: JsonNode = newJObject()
          let argStr = fn{"arguments"}.getStr("")
          if argStr.len > 0:
            try: input = parseJson(argStr)
            except CatchableError: input = newJObject()
          blocks.add(%*{"type": "tool_use", "id": tc{"id"}.getStr(),
                        "name": fn{"name"}.getStr(), "input": input})
      arr.add(%*{"role": "assistant", "content": blocks})
      inc i
    of "tool":
      var results = newJArray()
      while i < n and messages[i]{"role"}.getStr() == "tool":
        let tm = messages[i]
        results.add(%*{"type": "tool_result",
                       "tool_use_id": tm{"tool_call_id"}.getStr(),
                       "content": tm{"content"}.getStr()})
        inc i
      arr.add(%*{"role": "user", "content": results})
    else:
      inc i
  result = (sys, arr)

proc parseOpenAIAgentic(resp: Response): AgenticResult =
  let j = parseJson(resp.body)
  if not (j.hasKey("choices") and j["choices"].kind == JArray and j["choices"].len > 0):
    result.error = "Unexpected response: " & resp.body
    return
  let msg = j["choices"][0]{"message"}
  if msg == nil:
    result.error = "Unexpected response: " & resp.body
    return
  if msg.hasKey("content") and msg["content"].kind == JString:
    result.content = msg["content"].getStr()
  if msg.hasKey("reasoning_content") and msg["reasoning_content"].kind == JString:
    result.reasoning = msg["reasoning_content"].getStr()
  if msg.hasKey("tool_calls") and msg["tool_calls"].kind == JArray:
    for tc in msg["tool_calls"]:
      let fn = tc{"function"}
      if fn == nil: continue
      var argNode: JsonNode = newJObject()
      let argStr = fn{"arguments"}.getStr("")
      if argStr.len > 0:
        try: argNode = parseJson(argStr)
        except CatchableError: argNode = newJObject()
      result.toolCalls.add(AIToolCall(
        id: tc{"id"}.getStr(),
        name: fn{"name"}.getStr(),
        arguments: argNode))

proc parseAnthropicAgentic(resp: Response): AgenticResult =
  let j = parseJson(resp.body)
  if not (j.hasKey("content") and j["content"].kind == JArray):
    result.error = "Unexpected response: " & resp.body
    return
  var parts: seq[string]
  for blk in j["content"]:
    let bt = blk{"type"}.getStr()
    if bt == "text":
      parts.add(blk{"text"}.getStr())
    elif bt == "tool_use":
      let input = if blk.hasKey("input") and blk["input"].kind == JObject: blk["input"]
                  else: newJObject()
      result.toolCalls.add(AIToolCall(
        id: blk{"id"}.getStr(),
        name: blk{"name"}.getStr(),
        arguments: input))
  result.content = parts.join("\n")

proc doAgenticChat*(config: AppConfig, providerId, model: string,
                    messages: JsonNode, planMode: bool,
                    effort: string = ""): AgenticResult =
  ## One round-trip of the agentic loop: send the conversation (canonical
  ## OpenAI-format ``messages``) plus the tool schemas, and return the assistant
  ## text along with any tool calls it requested. On failure ``error`` is set.
  ## When ``effort`` is non-empty and the provider supports it (DeepSeek), the
  ## request opts into thinking mode at that reasoning effort and the reply's
  ## chain-of-thought is captured in ``result.reasoning``.
  ## Returns an error immediately if the requested model is disabled.
  if not isBuiltinModelEnabled(config, providerId, model):
    result.error = "Model disabled: " & providerId & "/" & model
    return
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let client = newChatClient(config, providerId)
  let defs = builtinToolDefs(planMode)

  var url, body: string
  if isAnthropicProvider(providerId):
    let (sys, msgs) = toAnthropicMessages(messages)
    url = baseUrl & "/messages"
    var bodyNode = %*{
      "model": model,
      "max_tokens": 4096,
      "messages": msgs,
      "tools": toAnthropicTools(defs)
    }
    if sys.len > 0:
      bodyNode["system"] = %sys
    body = $bodyNode
  else:
    url = baseUrl & "/chat/completions"
    var bodyNode = %*{
      "model": model,
      "messages": messages,
      "tools": toOpenAITools(defs),
      "tool_choice": "auto",
      "stream": false
    }
    if effort.len > 0:
      applyThinking(bodyNode, providerId, effort)
    body = $bodyNode

  try:
    let resp = retryableRequest(client, url, body)
    if resp.code.int div 100 != 2:
      result.error = "HTTP error " & $resp.code & ": " & resp.body
      return
    if isAnthropicProvider(providerId):
      result = parseAnthropicAgentic(resp)
    else:
      result = parseOpenAIAgentic(resp)
  except CatchableError as e:
    result.error = "Request failed: " & e.msg
  finally:
    client.close()

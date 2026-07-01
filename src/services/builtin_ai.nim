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

proc allBuiltinModels*(): seq[tuple[providerId, model, label: string]] =
  ## Flat list of every built-in model with a display label.
  for mp in BuiltinModelProviders:
    for m in mp.models:
      result.add((mp.id, m, mp.label & " — " & m))

proc isAnthropicProvider*(providerId: string): bool =
  ## Check if provider uses Anthropic API format (not OpenAI-compatible).
  providerId.toLowerAscii() == "anthropic"

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
  ## "HTTP error", "Request failed", or "Unexpected response".
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
  if provider.len == 0 or model.len == 0:
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
  ## "HTTP error", "Request failed", or "Unexpected response".
  let (providerId, _) = resolveBuiltinModel(config, prompt)
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
  ## "HTTP error", "Request failed", or "Unexpected response".
  let (providerId, _) = resolveBuiltinModel(config, prompt)
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

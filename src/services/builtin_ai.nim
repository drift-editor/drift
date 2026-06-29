## Built-in HTTP AI agent helpers
## Talks to OpenAI-compatible chat completions endpoints for model providers.
## The caller (ai_thread.nim) runs this in its own worker thread.

import std/[httpclient, json, os, strutils, uri]
import ../core/config
import ../services/git as gitcmd
import prompt_complexity

type BuiltinModelProvider* = object
  id*: string
  label*: string
  baseUrl*: string
  models*: seq[string]

const BuiltinModelProviders* = [
  BuiltinModelProvider(
    id: "openai",
    label: "OpenAI",
    baseUrl: "https://api.openai.com/v1",
    models: @["gpt-4o", "gpt-4o-mini", "o1", "o3-mini"]
  ),
  BuiltinModelProvider(
    id: "deepseek",
    label: "DeepSeek",
    baseUrl: "https://api.deepseek.com",
    models: @["deepseek-v4-flash", "deepseek-v4-pro"]
  ),
  BuiltinModelProvider(
    id: "moonshot",
    label: "Moonshot",
    baseUrl: "https://api.moonshot.cn/v1",
    models: @["kimi-for-coding"]
  ),
  BuiltinModelProvider(
    id: "groq",
    label: "Groq",
    baseUrl: "https://api.groq.com/openai/v1",
    models: @["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "gemma2-9b-it"]
  ),
  BuiltinModelProvider(
    id: "openrouter",
    label: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    models: @["openai/gpt-4o", "anthropic/claude-3.5-sonnet", "deepseek/deepseek-chat"]
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

proc makeChatRequest*(config: AppConfig, prompt: string): string =
  ## Build OpenAI-compatible /chat/completions request body.
  let (_, model) = resolveBuiltinModel(config, prompt)
  let messages = %*[{"role": "user", "content": prompt}]
  let body = %*{
    "model": model,
    "messages": messages,
    "stream": false
  }
  return $body

proc doChatCompletionWithModel*(config: AppConfig, prompt, providerId, model: string): string =
  ## Synchronous HTTP call to a specific provider/model.
  ## Returns the assistant message content, or an error string starting with
  ## "HTTP error", "Request failed", or "Unexpected response".
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let url = baseUrl & "/chat/completions"
  let client = newHttpClient(userAgent = "drift/1.0")
  client.headers = newHttpHeaders({
    "Content-Type": "application/json"
  })
  if config.aiApiKey.len > 0:
    client.headers["Authorization"] = "Bearer " & config.aiApiKey
  let body = %*{
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "stream": false
  }
  try:
    let resp = client.request(url, httpMethod = HttpPost, body = $body)
    if resp.code.int div 100 != 2:
      return "HTTP error " & $resp.code & ": " & resp.body
    let j = parseJson(resp.body)
    if j.hasKey("choices") and j["choices"].kind == JArray and j["choices"].len > 0:
      let choice = j["choices"][0]
      if choice.hasKey("message") and choice["message"].hasKey("content"):
        return choice["message"]["content"].getStr()
    return "Unexpected response: " & resp.body
  except CatchableError as e:
    return "Request failed: " & e.msg
  finally:
    client.close()

proc classifyGitIntent*(config: AppConfig, userText: string): bool =
  ## Ask the lightweight model whether the user is requesting git-related help.
  ## Falls back to false on any error so we don't block the main prompt.
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
  ## Synchronous HTTP call to the configured endpoint.
  ## Returns the assistant message content, or an error string starting with
  ## "HTTP error", "Request failed", or "Unexpected response".
  let (providerId, _) = resolveBuiltinModel(config, prompt)
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let url = baseUrl & "/chat/completions"
  let client = newHttpClient(userAgent = "drift/1.0")
  client.headers = newHttpHeaders({
    "Content-Type": "application/json"
  })
  if config.aiApiKey.len > 0:
    client.headers["Authorization"] = "Bearer " & config.aiApiKey
  let body = makeChatRequest(config, prompt)
  try:
    let resp = client.request(url, httpMethod = HttpPost, body = body)
    if resp.code.int div 100 != 2:
      return "HTTP error " & $resp.code & ": " & resp.body
    let j = parseJson(resp.body)
    if j.hasKey("choices") and j["choices"].kind == JArray and j["choices"].len > 0:
      let choice = j["choices"][0]
      if choice.hasKey("message") and choice["message"].hasKey("content"):
        return choice["message"]["content"].getStr()
    return "Unexpected response: " & resp.body
  except CatchableError as e:
    return "Request failed: " & e.msg
  finally:
    client.close()

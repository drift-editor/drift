## Best-effort detector for the active AI model by reading provider CLI configs.
## This is intentionally heuristic: each tool stores its model in different
## locations/formats, and some do not expose it at all.

import std/[os, json, strutils]

proc homeConfigPath(tool: string): string =
  getHomeDir() / "." & tool / "config.json"

proc projectConfigPath(workspaceRoot, tool: string): string =
  workspaceRoot / "." & tool / "config.json"

proc readJsonConfig(path: string): JsonNode =
  if not fileExists(path):
    return newJNull()
  try:
    return parseJson(readFile(path))
  except CatchableError:
    return newJNull()

proc extractModel(j: JsonNode): string =
  ## Look for common model keys in a provider config object.
  if j.isNil or j.kind != JObject:
    return ""
  let keys = ["model", "defaultModel", "modelId", "modelName", "agentModel", "chatModel"]
  for key in keys:
    if j.hasKey(key):
      let val = j[key]
      if val.kind == JString and val.getStr().len > 0:
        return val.getStr()
  # Nested objects like {"agent": {"model": "..."}}
  if j.hasKey("agent") and j["agent"].kind == JObject:
    let agent = j["agent"]
    for key in ["model", "defaultModel", "modelId"]:
      if agent.hasKey(key) and agent[key].kind == JString:
        return agent[key].getStr()
  return ""

proc detectAIModel*(providerId, workspaceRoot: string): string =
  ## Try to read the active model from a provider's CLI config files.
  ## Returns "" if nothing is found.
  let provider = providerId.toLowerAscii()
  var paths: seq[string]

  case provider
  of "kimi":
    paths.add(homeConfigPath("kimi-code"))
  of "claude":
    paths.add(homeConfigPath("claude-code"))
    paths.add(homeConfigPath("claude"))
    if workspaceRoot.len > 0:
      paths.add(projectConfigPath(workspaceRoot, "claude-code"))
      paths.add(projectConfigPath(workspaceRoot, "claude"))
  of "cursor":
    paths.add(homeConfigPath("cursor"))
  of "codex":
    paths.add(homeConfigPath("codex"))
  of "gemini":
    paths.add(homeConfigPath("gemini"))
  of "opencode":
    if workspaceRoot.len > 0:
      paths.add(projectConfigPath(workspaceRoot, "opencode"))
    paths.add(homeConfigPath("opencode"))
  of "custom":
    # Custom providers manage their own model; nothing to detect.
    discard
  else:
    discard

  for path in paths:
    let j = readJsonConfig(path)
    if j.kind == JObject:
      let model = extractModel(j)
      if model.len > 0:
        return model
  return ""

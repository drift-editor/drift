import ../src/services/prompt_complexity
import ../src/core/config

proc testBasicScoring() =
  let emptyScore = scorePromptComplexity("")
  assert emptyScore == 0, "empty prompt should score 0"

  let shortScore = scorePromptComplexity("hi")
  assert shortScore >= 0 and shortScore <= 100, "score out of range"

  let lightScore = scorePromptComplexity("rename this variable to foo")
  let heavyScore = scorePromptComplexity("""I need to refactor this large Nim module to use async/await throughout, handle all edge cases around cancellation, and review the resulting architecture for race conditions and memory leaks.

```nim
import std/asyncdispatch

proc oldSync(): string =
  result = "hello"

proc fetchAll(urls: seq[string]): Future[seq[string]] =
  var pending: seq[Future[string]]
  for u in urls:
    pending.add fetch(u)
  result = await all(pending)
```

Please:
1. Explain the trade-offs between sync and async designs.
2. Analyze potential deadlock scenarios.
3. Benchmark the throughput before and after.
4. Suggest data structures to minimize complexity.
""")
  assert heavyScore > lightScore, "heavy prompt should score higher than light prompt"
  assert heavyScore >= AutoComplexityThreshold, "heavy prompt should cross threshold"

proc testCodeBlockScoring() =
  let withCode = scorePromptComplexity("```nim\nproc foo(): int = 1\n```\nfix this")
  let withoutCode = scorePromptComplexity("fix this")
  assert withCode > withoutCode, "code blocks should increase score"

proc testMultiPartScoring() =
  let multi = scorePromptComplexity("1. foo\n2. bar\n3. baz?")
  let single = scorePromptComplexity("foo")
  assert multi > single, "multi-part prompt should score higher"

proc testResolveBuiltinModel() =
  var cfg = defaultConfig()
  cfg.aiModelPreset = "auto"
  cfg.aiLightweightModelProvider = "deepseek"
  cfg.aiLightweightModel = "deepseek-v4-flash"
  cfg.aiHeavyweightModelProvider = "deepseek"
  cfg.aiHeavyweightModel = "deepseek-v4-pro"

  let (_, light) = resolveBuiltinModel(cfg, "rename x")
  assert light == "deepseek-v4-flash", "simple prompt should use lightweight model"

  let heavyPrompt = """Refactor this large Nim module to use async/await, handle cancellation edge cases, review for race conditions and memory leaks, and benchmark throughput.

```nim
proc fetchAll(urls: seq[string]): Future[seq[string]] =
  var pending: seq[Future[string]]
  for u in urls:
    pending.add fetch(u)
  result = await all(pending)
```

Explain the trade-offs and suggest data structures to minimize complexity.
"""
  let (_, heavy) = resolveBuiltinModel(cfg, heavyPrompt)
  assert heavy == "deepseek-v4-pro", "complex prompt should use heavyweight model"

  cfg.aiModelPreset = "lightweight"
  let (_, forcedLight) = resolveBuiltinModel(cfg, "refactor everything")
  assert forcedLight == "deepseek-v4-flash", "lightweight preset should ignore prompt"

  cfg.aiModelPreset = "heavyweight"
  let (_, forcedHeavy) = resolveBuiltinModel(cfg, "hi")
  assert forcedHeavy == "deepseek-v4-pro", "heavyweight preset should ignore prompt"

proc testResolveBuiltinModelDisabled() =
  var cfg = defaultConfig()
  cfg.aiModelPreset = "lightweight"
  cfg.aiLightweightModelProvider = "deepseek"
  cfg.aiLightweightModel = "deepseek-v4-flash"
  cfg.aiHeavyweightModelProvider = "deepseek"
  cfg.aiHeavyweightModel = "deepseek-v4-pro"

  let (_, enabled) = resolveBuiltinModel(cfg, "rename x")
  assert enabled == "deepseek-v4-flash", "lightweight model should be enabled by default"

  cfg.aiEnabledModels = @["deepseek/deepseek-v4-pro"]
  let (disabledProvider, disabledModel) = resolveBuiltinModel(cfg, "rename x")
  assert disabledProvider == "" and disabledModel == "", "disabled lightweight model should return empty"

  cfg.aiModelPreset = "heavyweight"
  let (_, stillEnabled) = resolveBuiltinModel(cfg, "hi")
  assert stillEnabled == "deepseek-v4-pro", "heavyweight model should still be enabled"

proc testIsBuiltinModelEnabled() =
  var cfg = defaultConfig()
  assert isBuiltinModelEnabled(cfg, "deepseek", "deepseek-v4-flash") == true, "empty list means all enabled"
  cfg.aiEnabledModels = @["deepseek/deepseek-v4-pro"]
  assert isBuiltinModelEnabled(cfg, "deepseek", "deepseek-v4-pro") == true, "enabled model not recognized"
  assert isBuiltinModelEnabled(cfg, "deepseek", "deepseek-v4-flash") == false, "disabled model reported as enabled"

when isMainModule:
  testBasicScoring()
  testCodeBlockScoring()
  testMultiPartScoring()
  testResolveBuiltinModel()
  testResolveBuiltinModelDisabled()
  testIsBuiltinModelEnabled()
  echo "All prompt complexity tests passed!"

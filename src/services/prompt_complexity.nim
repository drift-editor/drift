## Prompt complexity scorer inspired by DEITA.
##
## DEITA selects high-quality instruction-tuning data by scoring complexity,
## quality, and diversity. We adapt the complexity idea to runtime routing:
## score the user's prompt and route complex prompts to a heavyweight model,
## simple prompts to a lightweight model.

import std/strutils
import ../core/config

const
  ReasoningKeywords* = [
    "explain", "why", "how does", "analyze", "compare", "design", "architecture",
    "refactor", "debug", "optimize", "review", "reasoning", "edge case",
    "trade-off", "tradeoff", "performance", "complexity", "threading",
    "concurrency", "algorithm", "data structure", "memory leak", "race condition",
    "benchmark", "profil", "async", "lock", "deadlock", "lifetime", "ownership"
  ]

  HeavyTaskKeywords* = [
    "refactor", "rewrite", "redesign", "architecture", "implement", "debug",
    "optimize", "review", "migrate", "unit test", "test case", "benchmark",
    "profile", "restructure", "reorganize", "simplify", "modernize"
  ]

  LightTaskKeywords* = [
    "rename", "format", "comment", "docstring", "summary", "short", "brief",
    "translate", "fix typo", "capitalize", "indent", "sort", "spell"
  ]

  AutoComplexityThreshold* = 45
    ## Score 0-100; prompts at or above this use the heavyweight model in Auto mode.

proc estimateTokens*(text: string): int {.inline.} =
  ## Rough token estimate: ~4 characters per token for CJK and code.
  result = text.len div 4

proc countCodeBlocks*(text: string): int =
  ## Count fenced code blocks (``` ... ```).
  var idx = 0
  while true:
    let found = text.find("```", idx)
    if found < 0:
      break
    inc result
    idx = found + 3

proc scorePromptComplexity*(prompt: string; contextLen: int = 0): int =
  ## Return a 0-100 complexity score for a prompt.
  ## Higher score => more suitable for a heavyweight model.
  if prompt.len == 0:
    return 0

  var score = 0
  let p = prompt.toLowerAscii()

  # 1. Length factor (0-30)
  let tokens = estimateTokens(prompt) + contextLen div 4
  score += min(30, tokens div 40)

  # 2. Code context factor (0-25)
  var codeScore = 0
  let codeBlocks = countCodeBlocks(prompt)
  codeScore += min(20, codeBlocks * 5)
  # Bonus for inline code density.
  let backticks = p.count('`')
  codeScore += min(10, backticks div 4)
  score += min(25, codeScore)

  # 3. Reasoning depth (0-20)
  var reasoningHits = 0
  for kw in ReasoningKeywords:
    if p.contains(kw):
      inc reasoningHits
  score += min(20, reasoningHits * 2)

  # 4. Task type (0-15)
  var taskScore = 0
  for kw in HeavyTaskKeywords:
    if p.contains(kw):
      taskScore = 15
      break
  if taskScore == 0:
    for kw in LightTaskKeywords:
      if p.contains(kw):
        taskScore = 2
        break
  score += taskScore

  # 5. Multi-part instructions (0-10)
  let questions = p.count('?')
  let bullets = p.count("\n-") + p.count("\n*") + p.count("\n1.") + p.count("\n2.") + p.count("\n3.")
  score += min(10, questions * 2 + bullets * 3)

  return min(100, score)

proc shouldUseHeavyweight*(config: AppConfig; prompt: string; contextLen: int = 0): bool =
  ## Decide whether an "auto" preset prompt should use the heavyweight model.
  if config.aiHeavyweightModel.len == 0:
    return false
  if config.aiLightweightModel.len == 0:
    return true
  return scorePromptComplexity(prompt, contextLen) >= AutoComplexityThreshold

proc resolveBuiltinModel*(config: AppConfig; prompt: string): tuple[provider, model: string] =
  ## Resolve the effective provider/model, routing "auto" by prompt complexity.
  ## Returns ("", "") when the selected model is explicitly disabled.
  let preset = config.aiModelPreset.toLowerAscii()
  if preset == "auto" and prompt.len > 0 and
      config.aiLightweightModel.len > 0 and config.aiHeavyweightModel.len > 0:
    if scorePromptComplexity(prompt) >= AutoComplexityThreshold:
      result = (config.aiHeavyweightModelProvider, config.aiHeavyweightModel)
    else:
      result = (config.aiLightweightModelProvider, config.aiLightweightModel)
  else:
    result = effectiveBuiltinModel(config)
  if not isBuiltinModelEnabled(config, result.provider, result.model):
    return ("", "")

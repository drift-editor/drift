## Tooltip overlay with lightweight Nim syntax highlighting

import uirelays
import uirelays/screen
import std/strutils
import ../utils/text
import ../editor/nim_highlighter

type
  Tooltip* = object
    text*: string
    x*, y*: int
    visible*: bool
    dirty*: bool
    cachedW*, cachedH*: int
    cachedLineH*: int
    cachedSections*: seq[tuple[kind: int, lines: seq[string], height: int]]

import theme

const
  TooltipPadding = 10
  TooltipMaxWidth = 400
  TooltipMinWidth = 160

proc newTooltip*(): Tooltip =
  Tooltip(visible: false, dirty: true)

proc showTooltip*(tt: var Tooltip; text: string; x, y: int) =
  if tt.text != text or tt.x != x or tt.y != y:
    tt.dirty = true
  tt.text = text
  tt.x = x
  tt.y = y
  tt.visible = true

proc hideTooltip*(tt: var Tooltip) =
  tt.visible = false
  tt.dirty = true

# Hover content parsing (ported from main branch)
proc parseHoverContent(text: string): tuple[signature: string, description: string, codeBlocks: seq[string]] =
  if text.len == 0:
    return ("", "", @[])
  let lines = text.splitLinesKeep()
  var signature = ""
  var description = ""
  var codeBlocks: seq[string] = @[]
  var inCodeBlock = false
  var currentCodeBlock = ""
  var foundSignature = false

  for line in lines:
    let trimmed = strip(line)
    if trimmed.startsWith("```"):
      if inCodeBlock:
        if currentCodeBlock.len > 0:
          var clean = currentCodeBlock
          while clean.endsWith("\n"): clean.setLen(clean.len - 1)
          if clean.len > 0: codeBlocks.add(clean)
        currentCodeBlock = ""
        inCodeBlock = false
      else:
        inCodeBlock = true
        currentCodeBlock = ""
    elif inCodeBlock:
      if currentCodeBlock.len > 0: currentCodeBlock.add("\n")
      currentCodeBlock.add(line)
    else:
      if trimmed.len > 0:
        if not foundSignature:
          signature = trimmed
          foundSignature = true
        else:
          if description.len > 0 and not description.endsWith("\n"):
            description.add("\n")
          description.add(line)
      elif description.len > 0 and foundSignature:
        if not description.endsWith("\n\n"):
          description.add("\n")

  if currentCodeBlock.len > 0:
    var clean = currentCodeBlock
    while clean.endsWith("\n"): clean.setLen(clean.len - 1)
    if clean.len > 0: codeBlocks.add(clean)
  while description.endsWith("\n"): description.setLen(description.len - 1)
  return (signature, description, codeBlocks)

proc tooltipBgColor*(): Color = currentTheme.getColor(tcBackground)
proc tooltipBorderColor*(): Color = currentTheme.getColor(tcBorder)
proc tooltipTextColor*(): Color = currentTheme.getColor(tcText)
proc tooltipCodeBgColor*(): Color = currentTheme.getColor(tcSurfaceHover)
proc tooltipSigBgColor*(): Color = currentTheme.getColor(tcSurface)

proc drawHighlightedLine(font: Font; x, y: int; text: string; bg: Color) =
  ## Draw a line with Nim syntax highlighting
  ## Delegates to the shared nim_highlighter module
  drawHighlightedNimLine(font, x, y, text, bg)

# Text wrapping (word-based, per-section)
proc wrapLines(text: string; font: Font; maxWidth: int): seq[string] =
  if text.len == 0: return @[""]
  let spaceW = measureText(font, " ").w
  for rawLine in text.splitLinesKeep():
    if rawLine.len == 0:
      result.add("")
      continue
    let words = rawLine.splitWhitespace()
    if words.len == 0:
      result.add("")
      continue
    var line = words[0]
    var lineW = measureText(font, line).w
    for i in 1 ..< words.len:
      let wordW = measureText(font, words[i]).w
      if lineW + spaceW + wordW <= maxWidth:
        line.add(" " & words[i])
        lineW += spaceW + wordW
      else:
        result.add(line)
        line = words[i]
        lineW = wordW
    result.add(line)

# Wrap code block lines, preserving leading indentation on continuation lines
proc wrapCodeLines(code: string; font: Font; maxWidth: int): seq[string] =
  if code.len == 0: return @[""]
  let spaceW = measureText(font, " ").w
  for rawLine in code.splitLinesKeep():
    if rawLine.len == 0:
      result.add("")
      continue
    let lineW = measureText(font, rawLine).w
    if lineW <= maxWidth:
      result.add(rawLine)
      continue
    # Find leading indentation
    var indentLen = 0
    while indentLen < rawLine.len and rawLine[indentLen] == ' ':
      inc indentLen
    let indent = rawLine[0 ..< indentLen]
    let indentW = measureText(font, indent).w
    let content = rawLine[indentLen .. ^1]
    let words = content.splitWhitespace()
    if words.len == 0:
      result.add(rawLine)
      continue
    var line = indent & words[0]
    var currLineW = indentW + measureText(font, words[0]).w
    for i in 1 ..< words.len:
      let wordW = measureText(font, words[i]).w
      if currLineW + spaceW + wordW <= maxWidth:
        line.add(" " & words[i])
        currLineW += spaceW + wordW
      else:
        result.add(line)
        line = indent & words[i]
        currLineW = indentW + wordW
    result.add(line)

# Tooltip render
proc render*(tt: var Tooltip; font: Font; viewportW, viewportH: int) =
  if not tt.visible or tt.text.len == 0:
    return

  let lineH = measureText(font, "Ay").h + 4
  let maxW = TooltipMaxWidth - TooltipPadding * 2
  let sectionGap = 6

  if tt.dirty or tt.cachedLineH != lineH:
    tt.dirty = false
    tt.cachedLineH = lineH
    let parsed = parseHoverContent(tt.text)
    tt.cachedSections = @[]
    var totalH = TooltipPadding * 2 - 4
    var maxLineW = 0

    if parsed.signature.len > 0:
      let sigLines = wrapLines(parsed.signature, font, maxW)
      let h = sigLines.len * lineH
      tt.cachedSections.add((0, sigLines, h))
      totalH += h
      for ln in sigLines:
        maxLineW = max(maxLineW, measureText(font, ln).w)

    if parsed.description.len > 0:
      let descLines = wrapLines(parsed.description, font, maxW)
      let h = descLines.len * lineH
      if tt.cachedSections.len > 0: totalH += sectionGap
      tt.cachedSections.add((1, descLines, h))
      totalH += h
      for ln in descLines:
        maxLineW = max(maxLineW, measureText(font, ln).w)

    for code in parsed.codeBlocks:
      let codeLines = wrapCodeLines(code, font, maxW)
      let h = codeLines.len * lineH
      if tt.cachedSections.len > 0: totalH += sectionGap
      tt.cachedSections.add((2, codeLines, h))
      totalH += h
      for ln in codeLines:
        maxLineW = max(maxLineW, measureText(font, ln).w)

    tt.cachedW = clamp(maxLineW + TooltipPadding * 2, TooltipMinWidth, TooltipMaxWidth)
    tt.cachedH = totalH

  var w = tt.cachedW
  var h = tt.cachedH

  # Clamp size to viewport
  w = min(w, viewportW - 8)
  h = min(h, viewportH - 8)

  var rx = tt.x + 12
  var ry = tt.y + 12
  if rx + w > viewportW: rx = max(4, tt.x - w - 4)
  if rx < 4: rx = 4
  if ry + h > viewportH: ry = max(4, tt.y - h - 4)
  if ry < 4: ry = 4

  # Background
  fillRect(rect(rx, ry, w, h), tooltipBgColor())
  fillRect(rect(rx, ry, w, 1), tooltipBorderColor())
  fillRect(rect(rx, ry + h - 1, w, 1), tooltipBorderColor())
  fillRect(rect(rx, ry, 1, h), tooltipBorderColor())
  fillRect(rect(rx + w - 1, ry, 1, h), tooltipBorderColor())

  # Render sections
  var cy = ry + TooltipPadding
  for sec in tt.cachedSections:
    if sec.kind == 0:
      fillRect(rect(rx + 1, cy, w - 2, sec.height), tooltipSigBgColor())
      for ln in sec.lines:
        drawHighlightedLine(font, rx + TooltipPadding, cy, ln, tooltipSigBgColor())
        cy += lineH
    elif sec.kind == 1:
      for ln in sec.lines:
        discard drawText(font, rx + TooltipPadding, cy, ln, tooltipTextColor(), tooltipBgColor())
        cy += lineH
    elif sec.kind == 2:
      fillRect(rect(rx + 1, cy, w - 2, sec.height), tooltipCodeBgColor())
      for ln in sec.lines:
        drawHighlightedLine(font, rx + TooltipPadding, cy, ln, tooltipCodeBgColor())
        cy += lineH
    cy += sectionGap

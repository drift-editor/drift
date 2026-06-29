## AI Chat Panel
## Right-side panel for AI conversations

import std/[strutils, unicode]
import uirelays
import uirelays/screen
import uirelays/input
import theme, icons

const
  HeaderHeight = 32
  InputHeight = 96
  ToolbarHeight = 24
  MessagePadding = 8
  MessageGap = 4
  ButtonWidth = 90
  ButtonHeight = 24
  ModelButtonWidth = 112

proc runeByteOffsets(s: string): seq[int] =
  ## Return the byte offset of every rune boundary, starting with 0 and ending with s.len.
  result.add(0)
  var off = 0
  for r in s.toRunes():
    off += ($r).len
    result.add(off)

proc prevRuneBoundary(s: string, bytePos: int): int =
  ## Return the byte index of the rune boundary immediately before bytePos.
  if bytePos <= 0:
    return 0
  let offsets = runeByteOffsets(s)
  for i in countdown(offsets.len - 2, 0):
    if offsets[i] < bytePos:
      return offsets[i]
  return 0

proc nextRuneBoundary(s: string, bytePos: int): int =
  ## Return the byte index immediately after the rune at bytePos.
  if bytePos >= s.len:
    return s.len
  let offsets = runeByteOffsets(s)
  for off in offsets:
    if off > bytePos:
      return off
  return s.len

type
  ChatMessage* = object
    role*: string
    content*: string

  BubbleLayout = object
    x, y, w, h: int
    textColor: Color
    bgColor: Color
    wrappedLines: seq[string]
    messageIndex: int

  AIPanel* = ref object
    messages*: seq[ChatMessage]
    inputText*: string
    cursorPos*: int
    scrollOffset*: int
    focused*: bool
    isStreaming*: bool
    cursorVisible*: bool
    lastBlinkTick*: int
    onSend*: proc(text: string)
    onNewSession*: proc()
    onStop*: proc()
    onAgentMenu*: proc(x, y: int)
    onModelMenu*: proc(x, y: int)
    hoverNewChat*: bool
    hoverAgentMenu*: bool
    hoverStop*: bool
    hoverModelMenu*: bool
    hoverInput*: bool
    placeholder*: string
    subtitle*: string
    modelPreset*: string
    showModelControls*: bool
    userScrolledUp*: bool
    rightClickedMessageIndex*: int

proc newAIPanel*(placeholder: string = "Ask AI..."): AIPanel =
  AIPanel(
    messages: @[],
    inputText: "",
    cursorPos: 0,
    scrollOffset: 0,
    focused: false,
    isStreaming: false,
    cursorVisible: true,
    lastBlinkTick: 0,
    onSend: nil,
    onNewSession: nil,
    onStop: nil,
    onAgentMenu: nil,
    onModelMenu: nil,
    hoverNewChat: false,
    hoverAgentMenu: false,
    hoverStop: false,
    hoverModelMenu: false,
    hoverInput: false,
    placeholder: placeholder,
    subtitle: "",
    modelPreset: "lightweight",
    showModelControls: false,
    userScrolledUp: false,
    rightClickedMessageIndex: -1
  )

proc sendCurrentMessage*(panel: AIPanel) =
  let text = panel.inputText.strip()
  if text.len == 0:
    return
  panel.messages.add(ChatMessage(role: "user", content: text))
  panel.inputText = ""
  panel.cursorPos = 0
  panel.cursorVisible = true
  panel.lastBlinkTick = getTicks()
  panel.userScrolledUp = false
  if panel.onSend != nil:
    panel.onSend(text)

proc clearChat*(panel: AIPanel) =
  panel.messages = @[]
  panel.scrollOffset = 0
  panel.isStreaming = false
  panel.inputText = ""
  panel.cursorPos = 0
  panel.userScrolledUp = false
  panel.rightClickedMessageIndex = -1

proc appendText*(panel: AIPanel, chunk: string) =
  panel.isStreaming = true
  if panel.messages.len == 0 or panel.messages[^1].role != "assistant":
    panel.messages.add(ChatMessage(role: "assistant", content: chunk))
  else:
    panel.messages[^1].content &= chunk
  if not panel.userScrolledUp:
    panel.scrollOffset = high(int)  ## Will be clamped to bottom during render

proc finalizeMessage*(panel: AIPanel) =
  panel.isStreaming = false

proc lastMessageContent*(panel: AIPanel): string =
  if panel.messages.len > 0:
    panel.messages[^1].content
  else:
    ""

proc copyLastAssistantMessage*(panel: AIPanel): bool =
  ## Copy the last assistant message to the clipboard.
  for i in countdown(panel.messages.high, 0):
    if panel.messages[i].role == "assistant":
      putClipboardText(panel.messages[i].content)
      return true
  return false

proc copyMessageAt*(panel: AIPanel, index: int): bool =
  if index >= 0 and index < panel.messages.len:
    putClipboardText(panel.messages[index].content)
    return true
  return false

proc bubbleTextColorFor(bg: Color): Color =
  ## Choose white or near-black text depending on accent luminance.
  let r = bg.r.float
  let g = bg.g.float
  let b = bg.b.float
  let luminance = 0.299 * r + 0.587 * g + 0.114 * b
  if luminance > 140:
    color(0, 0, 0, 255)
  else:
    color(255, 255, 255, 255)

proc wrapTextToWidth(text: string, font: Font, maxW: int): seq[string] =
  if text.len == 0:
    return @[]
  var lines: seq[string]
  for rawLine in text.split('\n'):
    var currentLine = ""
    for word in rawLine.split(' '):
      let test = if currentLine.len > 0: currentLine & " " & word else: word
      if font.measureText(test).w > maxW and currentLine.len > 0:
        lines.add(currentLine)
        currentLine = word
      else:
        currentLine = test
    if currentLine.len > 0:
      lines.add(currentLine)
    elif rawLine.len == 0:
      lines.add("")
  result = lines

proc cursorVisualPos(text: string, cursorPos: int, font: Font, maxW: int): tuple[line: int, x: int] =
  ## Compute which wrapped line the cursor is on and its x offset.
  if cursorPos <= 0:
    return (0, 0)
  var charIdx = 0
  var lineIdx = 0
  for rawLine in text.split('\n'):
    var currentLine = ""
    let words = rawLine.split(' ')
    for word in words:
      let spacePrefix = if currentLine.len > 0: " " else: ""
      let test = currentLine & spacePrefix & word
      if font.measureText(test).w > maxW and currentLine.len > 0:
        let lineStart = charIdx
        let lineEnd = charIdx + currentLine.len
        if cursorPos >= lineStart and cursorPos <= lineEnd:
          let offsetInLine = cursorPos - lineStart
          if offsetInLine <= 0 or offsetInLine > currentLine.len:
            return (lineIdx, 0)
          return (lineIdx, font.measureText(currentLine[0..<offsetInLine]).w)
        charIdx += currentLine.len
        if charIdx < text.len and text[charIdx] == ' ':
          charIdx += 1
        lineIdx += 1
        currentLine = word
      else:
        currentLine = test
    # End of raw line
    let lineStart = charIdx
    let lineEnd = charIdx + currentLine.len
    if cursorPos >= lineStart and cursorPos <= lineEnd:
      let offsetInLine = cursorPos - lineStart
      if offsetInLine <= 0 or offsetInLine > currentLine.len:
        return (lineIdx, 0)
      return (lineIdx, font.measureText(currentLine[0..<offsetInLine]).w)
    charIdx += currentLine.len
    if charIdx < text.len and text[charIdx] == '\n':
      charIdx += 1
    lineIdx += 1
  # Cursor at end
  let allLines = wrapTextToWidth(text, font, maxW)
  let lastLine = if allLines.len > 0: allLines[^1] else: ""
  return (max(0, allLines.len - 1), font.measureText(lastLine).w)

proc handleKey*(panel: AIPanel, e: Event): bool =
  if e.kind != KeyDownEvent:
    return false

  case e.key
  of KeyEnter:
    if ShiftPressed in e.mods:
      # Insert newline at cursor position
      if panel.cursorPos < panel.inputText.len:
        panel.inputText = panel.inputText[0..<panel.cursorPos] & "\n" & panel.inputText[panel.cursorPos..^1]
      else:
        panel.inputText.add("\n")
      inc panel.cursorPos
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
    else:
      panel.sendCurrentMessage()
      return true
  of KeyEsc:
    if panel.focused:
      panel.focused = false
      return true
    return false
  of KeyBackspace:
    if panel.cursorPos > 0:
      let start = prevRuneBoundary(panel.inputText, panel.cursorPos)
      panel.inputText = panel.inputText[0..<start] & panel.inputText[panel.cursorPos..^1]
      panel.cursorPos = start
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyDelete:
    if panel.cursorPos < panel.inputText.len:
      let endPos = nextRuneBoundary(panel.inputText, panel.cursorPos)
      panel.inputText = panel.inputText[0..<panel.cursorPos] & panel.inputText[endPos..^1]
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyLeft:
    if panel.cursorPos > 0:
      panel.cursorPos = prevRuneBoundary(panel.inputText, panel.cursorPos)
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyRight:
    if panel.cursorPos < panel.inputText.len:
      panel.cursorPos = nextRuneBoundary(panel.inputText, panel.cursorPos)
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyHome:
    panel.cursorPos = 0
    panel.cursorVisible = true
    panel.lastBlinkTick = getTicks()
    return true
  of KeyEnd:
    panel.cursorPos = panel.inputText.len
    panel.cursorVisible = true
    panel.lastBlinkTick = getTicks()
    return true
  of KeyV:
    let pasteMod = when defined(macosx): GuiPressed else: CtrlPressed
    if pasteMod in e.mods:
      let text = getClipboardText()
      if text.len > 0:
        if panel.cursorPos < panel.inputText.len:
          panel.inputText = panel.inputText[0..<panel.cursorPos] & text & panel.inputText[panel.cursorPos..^1]
        else:
          panel.inputText.add(text)
        panel.cursorPos += text.len
        panel.cursorVisible = true
        panel.lastBlinkTick = getTicks()
        return true
    return false
  of KeyC:
    if CtrlPressed in e.mods and ShiftPressed in e.mods:
      discard panel.copyLastAssistantMessage()
      return true
  of KeyPeriod:
    if CtrlPressed in e.mods and panel.isStreaming:
      if panel.onStop != nil:
        panel.onStop()
      return true
  else:
    discard
  false

proc handleTextInput*(panel: AIPanel, e: Event): bool =
  if not panel.focused:
    return false
  if e.kind != TextInputEvent:
    return false
  if e.text.len == 0:
    return false
  var text = ""
  for c in e.text:
    if c == '\0': break
    text.add(c)
  if text.len == 0 or text == "\b" or text == "\x7F":
    return false  # Backspace handled in handleKey
  if panel.cursorPos < panel.inputText.len:
    panel.inputText = panel.inputText[0..<panel.cursorPos] & text & panel.inputText[panel.cursorPos..^1]
  else:
    panel.inputText.add(text)
  panel.cursorPos += text.len
  panel.cursorVisible = true
  panel.lastBlinkTick = getTicks()
  return true

proc handleMouse*(panel: AIPanel, e: Event, bounds: Rect): bool =
  if e.kind == MouseDownEvent:
    let inputY = bounds.y + bounds.h - InputHeight
    let btnY = bounds.y + (HeaderHeight - ButtonHeight) div 2

    # Stop button (only when streaming)
    if panel.isStreaming:
      let stopX = bounds.x + bounds.w - ButtonWidth * 2 - 16
      let stopBounds = rect(stopX, btnY, ButtonWidth, ButtonHeight)
      if stopBounds.contains(point(e.x, e.y)):
        if panel.onStop != nil:
          panel.onStop()
        return true

    # New Chat icon button: choose provider to start a new agent session
    let iconBtnSize = 28
    let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
    let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
    let iconBtnBounds = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize)
    if iconBtnBounds.contains(point(e.x, e.y)):
      if panel.onAgentMenu != nil:
        panel.onAgentMenu(e.x, e.y)
      return true

    # Model selection dropdown above input box (unified preset/model picker)
    if panel.showModelControls:
      let toolbarY = inputY + 4
      let modelBtnBounds = rect(bounds.x + MessagePadding, toolbarY, ModelButtonWidth, ToolbarHeight - 2)
      if modelBtnBounds.contains(point(e.x, e.y)):
        if panel.onModelMenu != nil:
          panel.onModelMenu(e.x, e.y)
        return true

    let inputContentTop = if panel.showModelControls: inputY + ToolbarHeight else: inputY
    if e.y >= inputContentTop:
      panel.focused = true
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
    else:
      # Clicking messages area defocuses input but does not steal panel focus
      panel.focused = false
    return true

  if e.kind == MouseMoveEvent:
    let btnY = bounds.y + (HeaderHeight - ButtonHeight) div 2
    let iconBtnSize = 28
    let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
    let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
    panel.hoverNewChat = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize).contains(point(e.x, e.y))
    panel.hoverAgentMenu = panel.hoverNewChat
    panel.hoverModelMenu = false
    panel.hoverInput = false
    if panel.showModelControls:
      let inputY = bounds.y + bounds.h - InputHeight
      let toolbarY = inputY + 4
      let modelBtnBounds = rect(bounds.x + MessagePadding, toolbarY, ModelButtonWidth, ToolbarHeight - 2)
      panel.hoverModelMenu = modelBtnBounds.contains(point(e.x, e.y))
      # Input text area starts below the model toolbar
      panel.hoverInput = e.y >= inputY + ToolbarHeight
    else:
      let inputY = bounds.y + bounds.h - InputHeight
      panel.hoverInput = e.y >= inputY
    if panel.isStreaming:
      let stopX = bounds.x + bounds.w - ButtonWidth * 2 - 16
      panel.hoverStop = rect(stopX, btnY, ButtonWidth, ButtonHeight).contains(point(e.x, e.y))
    else:
      panel.hoverStop = false
    return true

  if e.kind == MouseWheelEvent:
    let oldOffset = panel.scrollOffset
    # Avoid overflow when scrollOffset is the sentinel high(int) used before render clamping.
    var base = int64(panel.scrollOffset)
    if base >= int64(high(int)) - 1_000_000:
      base = int64(high(int)) - 1_000_000
    let wheelDelta = clamp(int64(e.y), -1_000_000, 1_000_000)
    let newOffset = base + wheelDelta * 20
    panel.scrollOffset = int(clamp(newOffset, 0, int64(high(int))))
    # userScrolledUp is determined at render time after clamping to content height
    if panel.scrollOffset != oldOffset:
      return true
  false

proc computeBubbleLayouts(panel: AIPanel, font: Font, bounds: Rect): seq[BubbleLayout] =
  let maxW = bounds.w - MessagePadding * 4
  let fm = font.getFontMetrics()
  var y = MessagePadding
  for i, msg in panel.messages:
    let isUser = msg.role == "user"
    let bgColor = if isUser: currentTheme.getColor(tcAccent) else: currentTheme.getColor(tcBackground)

    let lines = msg.content.splitLines()
    var wrappedLines: seq[string]
    var totalH = 0
    for line in lines:
      let ext = font.measureText(line)
      if ext.w <= maxW:
        wrappedLines.add(line)
        totalH += fm.lineHeight
      else:
        var currentLine = ""
        for word in line.split(' '):
          let test = if currentLine.len > 0: currentLine & " " & word else: word
          let testW = font.measureText(test).w
          if testW > maxW and currentLine.len > 0:
            wrappedLines.add(currentLine)
            totalH += fm.lineHeight
            currentLine = word
          else:
            currentLine = test
        if currentLine.len > 0:
          wrappedLines.add(currentLine)
          totalH += fm.lineHeight

    let bubbleH = totalH + MessagePadding * 2
    let bubbleW = bounds.w - MessagePadding * 2
    let bubbleX = if isUser:
      bounds.x + bounds.w - bubbleW - MessagePadding
    else:
      bounds.x + MessagePadding

    result.add(BubbleLayout(
      x: bubbleX, y: y, w: bubbleW, h: bubbleH,
      textColor: bubbleTextColorFor(bgColor),
      bgColor: bgColor,
      wrappedLines: wrappedLines,
      messageIndex: i
    ))
    y += bubbleH + MessageGap

proc messageIndexAt*(panel: AIPanel, y: int, font: Font, bounds: Rect): int =
  ## Return the message index at the given screen Y, or -1.
  let messagesY = bounds.y + HeaderHeight
  let messagesH = max(0, bounds.h - HeaderHeight - InputHeight)
  if y < messagesY or y >= messagesY + messagesH:
    return -1
  let layouts = computeBubbleLayouts(panel, font, bounds)
  let contentY = y - messagesY + panel.scrollOffset
  for bubble in layouts:
    if contentY >= bubble.y and contentY < bubble.y + bubble.h:
      return bubble.messageIndex
  return -1

proc render*(panel: AIPanel, font: Font, bounds: Rect) =
  let bg = currentTheme.getColor(tcSurface)
  let borderC = currentTheme.getColor(tcBorder)
  let textC = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let accentC = currentTheme.getColor(tcAccent)
  let headerBg = currentTheme.getColor(tcBackground)
  let bgHover = currentTheme.getColor(tcSurfaceHover)
  let fm = font.getFontMetrics()

  # Panel background
  fillRect(bounds, bg)

  # Header
  fillRect(rect(bounds.x, bounds.y, bounds.w, HeaderHeight), headerBg)
  fillRect(rect(bounds.x, bounds.y + HeaderHeight - 1, bounds.w, 1), borderC)
  let headerTextY = bounds.y + (HeaderHeight - fm.lineHeight) div 2
  discard font.drawText(bounds.x + 12, headerTextY, "AI Chat", textC, color(0, 0, 0, 0))
  if panel.subtitle.len > 0:
    let subtitleW = font.measureText(panel.subtitle).w
    let subtitleX = bounds.x + bounds.w - 108 - subtitleW
    let minSubtitleX = bounds.x + 80
    if subtitleX >= minSubtitleX:
      discard font.drawText(subtitleX, headerTextY, panel.subtitle, textMuted, color(0, 0, 0, 0))

  # Header buttons
  let btnY = bounds.y + (HeaderHeight - ButtonHeight) div 2

  # Stop button (only when streaming)
  if panel.isStreaming:
    let stopX = bounds.x + bounds.w - ButtonWidth * 2 - 16
    let stopBorderC = if panel.hoverStop: accentC else: borderC
    let stopBounds = rect(stopX, btnY, ButtonWidth, ButtonHeight)
    fillRect(stopBounds, bg)
    fillRect(rect(stopBounds.x, stopBounds.y, stopBounds.w, 1), stopBorderC)
    fillRect(rect(stopBounds.x, stopBounds.y + stopBounds.h - 1, stopBounds.w, 1), stopBorderC)
    fillRect(rect(stopBounds.x, stopBounds.y, 1, stopBounds.h), stopBorderC)
    fillRect(rect(stopBounds.x + stopBounds.w - 1, stopBounds.y, 1, stopBounds.h), stopBorderC)
    let stopLabel = "Stop"
    let stopW = font.measureText(stopLabel).w
    discard font.drawText(stopBounds.x + (ButtonWidth - stopW) div 2, stopBounds.y + 4, stopLabel, textC, color(0, 0, 0, 0))

  # New Chat icon button (soft hover fill, consistent with other icon buttons)
  let iconBtnSize = 28
  let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
  let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
  let iconBtnBounds = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize)
  if panel.hoverNewChat:
    fillRect(iconBtnBounds, bgHover)
  drawIconCentered(iiAdd, iconBtnBounds)

  # Messages area
  let messagesY = bounds.y + HeaderHeight
  let messagesH = max(0, bounds.h - HeaderHeight - InputHeight)
  let messagesBounds = rect(bounds.x, messagesY, bounds.w, messagesH)

  # Clip messages area
  setClipRect(messagesBounds)

  # Compute layouts
  let bubbles = computeBubbleLayouts(panel, font, bounds)

  # Compute total content height
  var contentHeight = MessagePadding
  if bubbles.len > 0:
    contentHeight = bubbles[^1].y + bubbles[^1].h + MessageGap
  if panel.isStreaming:
    contentHeight += fm.lineHeight

  # Clamp scroll offset to content
  let maxScroll = max(0, contentHeight - messagesH)
  if panel.scrollOffset > maxScroll:
    panel.scrollOffset = maxScroll
  if panel.scrollOffset < 0:
    panel.scrollOffset = 0

  # Determine whether user has intentionally scrolled away from the bottom.
  panel.userScrolledUp = panel.scrollOffset < maxScroll

  # Render visible bubbles
  for bubble in bubbles:
    let drawY = messagesY + bubble.y - panel.scrollOffset
    if drawY + bubble.h > messagesY and drawY < messagesY + messagesH:
      fillRect(rect(bubble.x, drawY, bubble.w, bubble.h), bubble.bgColor)
      fillRect(rect(bubble.x, drawY, bubble.w, 1), borderC)
      fillRect(rect(bubble.x, drawY + bubble.h - 1, bubble.w, 1), borderC)
      fillRect(rect(bubble.x, drawY, 1, bubble.h), borderC)
      fillRect(rect(bubble.x + bubble.w - 1, drawY, 1, bubble.h), borderC)

      var lineY = drawY + MessagePadding
      for line in bubble.wrappedLines:
        discard font.drawText(bubble.x + MessagePadding, lineY, line, bubble.textColor, color(0, 0, 0, 0))
        lineY += fm.lineHeight

  # Streaming indicator
  if panel.isStreaming:
    let indicatorY = messagesY + contentHeight - fm.lineHeight - panel.scrollOffset
    if indicatorY > messagesY and indicatorY < messagesY + messagesH:
      discard font.drawText(bounds.x + MessagePadding, indicatorY, ".", textMuted, color(0, 0, 0, 0))

  restoreState()

  # Input area
  let inputY = bounds.y + bounds.h - InputHeight
  fillRect(rect(bounds.x, inputY, bounds.w, InputHeight), headerBg)
  fillRect(rect(bounds.x, inputY, bounds.w, 1), borderC)

  # Model selector dropdown above input box (built-in agent only)
  if panel.showModelControls:
    let toolbarY = inputY + 4
    let modelBtnBounds = rect(bounds.x + MessagePadding, toolbarY, ModelButtonWidth, ToolbarHeight - 2)
    let preset = panel.modelPreset.toLowerAscii()
    let modelLabel = case preset
      of "auto": "Auto"
      of "heavyweight": "Heavy"
      else: "Light"
    # Color-coded status dot identifies the active preset at a glance
    let dotColor = case preset
      of "auto": currentTheme.getColor(tcInfo)
      of "heavyweight": currentTheme.getColor(tcWarning)
      else: currentTheme.getColor(tcSuccess)

    # Background: subtle hover fill makes the control feel interactive
    let btnBg = if panel.hoverModelMenu: currentTheme.getColor(tcSurfaceHover) else: bg
    fillRect(modelBtnBounds, btnBg)
    # Border: accent on hover, normal border otherwise
    let modelBtnBorderC = if panel.hoverModelMenu: accentC else: borderC
    fillRect(rect(modelBtnBounds.x, modelBtnBounds.y, modelBtnBounds.w, 1), modelBtnBorderC)
    fillRect(rect(modelBtnBounds.x, modelBtnBounds.y + modelBtnBounds.h - 1, modelBtnBounds.w, 1), modelBtnBorderC)
    fillRect(rect(modelBtnBounds.x, modelBtnBounds.y, 1, modelBtnBounds.h), modelBtnBorderC)
    fillRect(rect(modelBtnBounds.x + modelBtnBounds.w - 1, modelBtnBounds.y, 1, modelBtnBounds.h), modelBtnBorderC)

    let textY = modelBtnBounds.y + (modelBtnBounds.h - fm.lineHeight) div 2

    # Status dot (left)
    let dotCx = modelBtnBounds.x + 12
    let dotCy = modelBtnBounds.y + modelBtnBounds.h div 2
    fillRect(rect(dotCx - 2, dotCy - 2, 4, 4), dotColor)

    # Label
    discard font.drawText(modelBtnBounds.x + 20, textY, modelLabel, textC, color(0, 0, 0, 0))

    # Vertical separator before the chevron (dropdown affordance)
    let sepX = modelBtnBounds.x + modelBtnBounds.w - 22
    fillRect(rect(sepX, modelBtnBounds.y + 4, 1, modelBtnBounds.h - 8), borderC)

    # Chevron-down icon (the dropdown arrow)
    drawIconCentered(iiChevronDown, rect(sepX + 2, modelBtnBounds.y, 18, modelBtnBounds.h))

  let inputBounds = rect(
    bounds.x + MessagePadding,
    inputY + ToolbarHeight + 6,
    bounds.w - MessagePadding * 2,
    InputHeight - ToolbarHeight - 12
  )
  fillRect(inputBounds, bg)
  let inputBorderColor = if panel.focused: accentC else: borderC
  fillRect(rect(inputBounds.x, inputBounds.y, inputBounds.w, 1), inputBorderColor)
  fillRect(rect(inputBounds.x, inputBounds.y + inputBounds.h - 1, inputBounds.w, 1), inputBorderColor)
  fillRect(rect(inputBounds.x, inputBounds.y, 1, inputBounds.h), inputBorderColor)
  fillRect(rect(inputBounds.x + inputBounds.w - 1, inputBounds.y, 1, inputBounds.h), inputBorderColor)

  let innerTextW = max(0, inputBounds.w - 16)
  let inputLines = wrapTextToWidth(panel.inputText, font, innerTextW)

  if panel.inputText.len == 0:
    discard font.drawText(inputBounds.x + 8, inputBounds.y + 8, panel.placeholder, textMuted, color(0, 0, 0, 0))
  else:
    var lineY = inputBounds.y + 8
    for line in inputLines:
      discard font.drawText(inputBounds.x + 8, lineY, line, textC, color(0, 0, 0, 0))
      lineY += fm.lineHeight

  # Cursor blink
  var blink = false
  if panel.focused:
    let ticks = getTicks()
    if ticks - panel.lastBlinkTick > 500:
      panel.cursorVisible = not panel.cursorVisible
      panel.lastBlinkTick = ticks
    blink = panel.cursorVisible

  if panel.focused and blink:
    let (cursorLine, cursorX) = cursorVisualPos(panel.inputText, panel.cursorPos, font, innerTextW)
    let drawCursorX = inputBounds.x + 8 + cursorX
    let drawCursorY = inputBounds.y + 8 + cursorLine * fm.lineHeight
    fillRect(rect(drawCursorX, drawCursorY, 2, fm.lineHeight), textC)

  # Resize handle at left edge
  let handleX = bounds.x + 2
  let midY = bounds.y + bounds.h div 2
  for i in 0..2:
    fillRect(rect(handleX, midY - 8 + i * 6, 2, 2), borderC)

  # Left border (drawn last so it shows through the header)
  fillRect(rect(bounds.x, bounds.y, 1, bounds.h), borderC)

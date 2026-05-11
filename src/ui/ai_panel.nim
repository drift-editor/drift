## AI Chat Panel
## Right-side panel for AI conversations

import std/strutils
import uirelays
import uirelays/screen
import uirelays/input
import theme, icons

const
  HeaderHeight = 32
  InputHeight = 72
  MessagePadding = 8
  MessageGap = 4
  MaxMessageWidth = 220
  ButtonWidth = 90
  ButtonHeight = 24

type
  ChatMessage* = object
    role*: string
    content*: string

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
    hoverNewChat*: bool
    hoverClear*: bool
    hoverStop*: bool

proc newAIPanel*(): AIPanel =
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
    hoverNewChat: false,
    hoverClear: false,
    hoverStop: false
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
  if panel.onSend != nil:
    panel.onSend(text)

proc clearChat*(panel: AIPanel) =
  panel.messages = @[]
  panel.scrollOffset = 0
  panel.isStreaming = false
  panel.inputText = ""
  panel.cursorPos = 0

proc appendText*(panel: AIPanel, chunk: string) =
  panel.isStreaming = true
  if panel.messages.len == 0 or panel.messages[^1].role != "assistant":
    panel.messages.add(ChatMessage(role: "assistant", content: chunk))
  else:
    panel.messages[^1].content &= chunk

proc finalizeMessage*(panel: AIPanel) =
  panel.isStreaming = false

proc lastMessageContent*(panel: AIPanel): string =
  if panel.messages.len > 0:
    panel.messages[^1].content
  else:
    ""

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
          return (lineIdx, font.measureText(currentLine[0..<offsetInLine]).w)
        # Advance charIdx by the actual characters consumed in original text
        # currentLine may consist of multiple words separated by single spaces
        # We need to find how many chars in rawLine correspond to currentLine
        charIdx += currentLine.len
        if currentLine.len < rawLine.len:
          charIdx += 1  # skip one space
        lineIdx += 1
        currentLine = word
      else:
        currentLine = test
    # End of raw line
    let lineStart = charIdx
    let lineEnd = charIdx + currentLine.len
    if cursorPos >= lineStart and cursorPos <= lineEnd:
      let offsetInLine = cursorPos - lineStart
      if offsetInLine <= 0:
        return (lineIdx, 0)
      return (lineIdx, font.measureText(currentLine[0..<offsetInLine]).w)
    charIdx += currentLine.len
    if charIdx < text.len and text[charIdx] == '\n':
      charIdx += 1  # skip newline
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
    panel.focused = false
    return true
  of KeyBackspace:
    if panel.cursorPos > 0:
      if panel.cursorPos < panel.inputText.len:
        panel.inputText = panel.inputText[0..<panel.cursorPos - 1] & panel.inputText[panel.cursorPos..^1]
      else:
        panel.inputText.setLen(panel.inputText.len - 1)
      dec panel.cursorPos
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyDelete:
    if panel.cursorPos < panel.inputText.len:
      if panel.cursorPos == 0:
        panel.inputText = panel.inputText[1..^1]
      else:
        panel.inputText = panel.inputText[0..<panel.cursorPos] & panel.inputText[panel.cursorPos + 1..^1]
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyLeft:
    if panel.cursorPos > 0:
      dec panel.cursorPos
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  of KeyRight:
    if panel.cursorPos < panel.inputText.len:
      inc panel.cursorPos
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

    # New Chat icon button
    let iconBtnSize = 28
    let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
    let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
    let iconBtnBounds = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize)
    if iconBtnBounds.contains(point(e.x, e.y)):
      panel.clearChat()
      if panel.onNewSession != nil:
        panel.onNewSession()
      return true

    if e.y >= inputY:
      panel.focused = true
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
    else:
      panel.focused = false
    return true

  if e.kind == MouseMoveEvent:
    let btnY = bounds.y + (HeaderHeight - ButtonHeight) div 2
    let iconBtnSize = 28
    let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
    let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
    panel.hoverNewChat = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize).contains(point(e.x, e.y))
    if panel.isStreaming:
      let stopX = bounds.x + bounds.w - ButtonWidth * 2 - 16
      panel.hoverStop = rect(stopX, btnY, ButtonWidth, ButtonHeight).contains(point(e.x, e.y))
    else:
      panel.hoverStop = false
    return true

  if e.kind == MouseWheelEvent:
    panel.scrollOffset += e.y * 20
    if panel.scrollOffset < 0:
      panel.scrollOffset = 0
    return true
  false

proc render*(panel: AIPanel, font: Font, bounds: Rect) =
  let bg = currentTheme.getColor(tcSurface)
  let borderC = currentTheme.getColor(tcBorder)
  let textC = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let accentC = currentTheme.getColor(tcAccent)
  let headerBg = currentTheme.getColor(tcBackground)

  # Panel background
  fillRect(bounds, bg)

  # Header
  fillRect(rect(bounds.x, bounds.y, bounds.w, HeaderHeight), headerBg)
  fillRect(rect(bounds.x, bounds.y + HeaderHeight - 1, bounds.w, 1), borderC)
  let fm = font.getFontMetrics()
  let headerTextY = bounds.y + (HeaderHeight - fm.lineHeight) div 2
  discard font.drawText(bounds.x + 12, headerTextY, "AI Chat", textC, color(0, 0, 0, 0))

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

  # New Chat icon button
  let iconBtnSize = 28
  let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
  let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
  let iconBtnBounds = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize)
  if panel.hoverNewChat:
    fillRect(iconBtnBounds, bg)
    fillRect(rect(iconBtnBounds.x, iconBtnBounds.y, iconBtnBounds.w, 1), accentC)
    fillRect(rect(iconBtnBounds.x, iconBtnBounds.y + iconBtnBounds.h - 1, iconBtnBounds.w, 1), accentC)
    fillRect(rect(iconBtnBounds.x, iconBtnBounds.y, 1, iconBtnBounds.h), accentC)
    fillRect(rect(iconBtnBounds.x + iconBtnBounds.w - 1, iconBtnBounds.y, 1, iconBtnBounds.h), accentC)
  drawIconCentered(iiAdd, iconBtnBounds)

  # Messages area
  let messagesY = bounds.y + HeaderHeight
  let messagesH = max(0, bounds.h - HeaderHeight - InputHeight)
  let messagesBounds = rect(bounds.x, messagesY, bounds.w, messagesH)

  # Clip messages area
  setClipRect(messagesBounds)

  var y = messagesY + MessagePadding - panel.scrollOffset

  for msg in panel.messages:
    let isUser = msg.role == "user"
    let bubbleColor = if isUser: accentC else: headerBg
    let bubbleTextC = if isUser: color(255, 255, 255, 255) else: textC

    # Measure text and wrap if needed
    let maxW = min(MaxMessageWidth, bounds.w - 32)
    let lines = msg.content.splitLines()
    var wrappedLines: seq[string]
    var totalH = 0
    for line in lines:
      let ext = font.measureText(line)
      if ext.w <= maxW:
        wrappedLines.add(line)
        totalH += fm.lineHeight
      else:
        # Simple word wrap
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
    let bubbleW = min(bounds.w - 16, maxW + MessagePadding * 2)
    let bubbleX = if isUser:
      bounds.x + bounds.w - bubbleW - MessagePadding
    else:
      bounds.x + MessagePadding

    if y + bubbleH > messagesY and y < messagesY + messagesH:
      fillRect(rect(bubbleX, y, bubbleW, bubbleH), bubbleColor)
      fillRect(rect(bubbleX, y, bubbleW, 1), borderC)
      fillRect(rect(bubbleX, y + bubbleH - 1, bubbleW, 1), borderC)
      fillRect(rect(bubbleX, y, 1, bubbleH), borderC)
      fillRect(rect(bubbleX + bubbleW - 1, y, 1, bubbleH), borderC)

      var lineY = y + MessagePadding
      for line in wrappedLines:
        discard font.drawText(bubbleX + MessagePadding, lineY, line, bubbleTextC, color(0, 0, 0, 0))
        lineY += fm.lineHeight

    y += bubbleH + MessageGap

  # Streaming indicator
  if panel.isStreaming:
    let indicatorY = y + MessagePadding
    if indicatorY > messagesY and indicatorY < messagesY + messagesH:
      let dots = "."
      discard font.drawText(bounds.x + MessagePadding, indicatorY, dots, textMuted, color(0, 0, 0, 0))

  restoreState()

  # Input area
  let inputY = bounds.y + bounds.h - InputHeight
  fillRect(rect(bounds.x, inputY, bounds.w, InputHeight), headerBg)
  fillRect(rect(bounds.x, inputY, bounds.w, 1), borderC)

  let inputBounds = rect(
    bounds.x + MessagePadding,
    inputY + 6,
    bounds.w - MessagePadding * 2,
    InputHeight - 12
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
    discard font.drawText(inputBounds.x + 8, inputBounds.y + 8, "Ask Kimi...", textMuted, color(0, 0, 0, 0))
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

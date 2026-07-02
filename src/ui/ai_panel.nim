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
  ModelButtonWidth = 112
  VariantsButtonWidth = 58
  MaxMessages = 200        ## Cap stored messages to bound memory growth.
  MaxInputLen = 8000       ## Cap input text to prevent pathological input.
  StreamingAnimFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

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
    thinking*: string   ## Reasoning/thinking content, shown separately (muted)

  BubbleLayout = object
    x, y, w, h: int
    textColor: Color
    bgColor: Color
    wrappedLines: seq[string]
    thinkingLines: seq[string]
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
    onPlanModeToggle*: proc()
    onVariantsMenu*: proc(x, y: int)
    hoverNewChat*: bool
    hoverAgentMenu*: bool
    hoverStop*: bool
    hoverModelMenu*: bool
    hoverPlanMode*: bool
    hoverVariants*: bool
    hoverInput*: bool
    placeholder*: string
    subtitle*: string
    modelPreset*: string
    showModelControls*: bool
    showVariants*: bool          ## Show the reasoning-effort variants button (thinking-capable provider only).
    reasoningEffort*: string     ## Current effort label shown on the variants button ("high"/"max").
    planMode*: bool
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
    onPlanModeToggle: nil,
    hoverNewChat: false,
    hoverAgentMenu: false,
    hoverStop: false,
    hoverModelMenu: false,
    hoverPlanMode: false,
    hoverVariants: false,
    hoverInput: false,
    placeholder: placeholder,
    subtitle: "",
    modelPreset: "lightweight",
    showModelControls: false,
    showVariants: false,
    reasoningEffort: "high",
    userScrolledUp: false,
    rightClickedMessageIndex: -1
  )

proc sendCurrentMessage*(panel: AIPanel) =
  let text = panel.inputText.strip()
  if text.len == 0:
    return
  panel.messages.add(ChatMessage(role: "user", content: text))
  # Prune oldest messages to bound memory growth.
  while panel.messages.len > MaxMessages:
    panel.messages.delete(0)
  panel.inputText = ""
  panel.cursorPos = 0
  panel.cursorVisible = true
  panel.lastBlinkTick = getTicks()
  # Only auto-scroll to the new message if the user is already near the bottom.
  # If they scrolled up to read history, keep their position.
  if not panel.userScrolledUp:
    panel.scrollOffset = high(int)  ## Will be clamped to bottom during render
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

proc appendThinking*(panel: AIPanel, chunk: string) =
  ## Append a thinking/reasoning chunk to the current (or a new) assistant
  ## message. Thinking content is stored separately and rendered muted, so it
  ## never merges into the response text.
  panel.isStreaming = true
  if panel.messages.len == 0 or panel.messages[^1].role != "assistant":
    panel.messages.add(ChatMessage(role: "assistant", content: "", thinking: chunk))
  else:
    panel.messages[^1].thinking &= chunk
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
  if maxW <= 0:
    return @[text]
  var lines: seq[string]
  for rawLine in text.split('\n'):
    var currentLine = ""
    for word in rawLine.split(' '):
      # If a single word is wider than maxW, hard-break it by character so long
      # URLs/identifiers don't overflow the bubble.
      var w = word
      while font.measureText(w).w > maxW and w.len > 1:
        # Find the longest prefix of w that fits.
        var cut = w.len
        while cut > 1 and font.measureText(w[0..<cut]).w > maxW:
          dec cut
        if cut < 1: cut = 1
        let chunk = w[0..<cut]
        if currentLine.len > 0:
          lines.add(currentLine)
          currentLine = ""
        lines.add(chunk)
        w = w[cut..^1]
      let test = if currentLine.len > 0: currentLine & " " & w else: w
      if font.measureText(test).w > maxW and currentLine.len > 0:
        lines.add(currentLine)
        currentLine = w
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
        # Replace the clipboard text with a normalized version (strip trailing null)
        var cleanText = text
        # Remove trailing null characters if any
        while cleanText.len > 0 and cleanText[^1] == '\0':
          cleanText.setLen(cleanText.len - 1)
        if cleanText.len > 0:
          # Enforce input length limit
          if panel.inputText.len + cleanText.len > MaxInputLen:
            cleanText = cleanText[0 ..< (MaxInputLen - panel.inputText.len)]
          if panel.cursorPos < panel.inputText.len:
            panel.inputText = panel.inputText[0..<panel.cursorPos] & cleanText & panel.inputText[panel.cursorPos..^1]
          else:
            panel.inputText.add(cleanText)
          panel.cursorPos += cleanText.len
          panel.cursorVisible = true
          panel.lastBlinkTick = getTicks()
          return true
    return false
  of KeyC:
    let copyMod = when defined(macosx): GuiPressed else: CtrlPressed
    if copyMod in e.mods and ShiftPressed in e.mods:
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

proc handlePasteViaTextInput*(panel: AIPanel, text: string): bool =
  ## Handle paste from the OS clipboard, typically delivered as a TextInput event
  ## with the full clipboard content. Bypasses the character-by-character handling
  ## that would otherwise break on multi-line or large pastes.
  if not panel.focused:
    return false
  if text.len == 0:
    return false
  var cleanText = text
  # Remove trailing null characters if any
  while cleanText.len > 0 and cleanText[^1] == '\0':
    cleanText.setLen(cleanText.len - 1)
  if cleanText.len == 0:
    return false
  # Enforce input length limit
  if panel.inputText.len + cleanText.len > MaxInputLen:
    cleanText = cleanText[0 ..< (MaxInputLen - panel.inputText.len)]
  if panel.cursorPos < panel.inputText.len:
    panel.inputText = panel.inputText[0..<panel.cursorPos] & cleanText & panel.inputText[panel.cursorPos..^1]
  else:
    panel.inputText.add(cleanText)
  panel.cursorPos += cleanText.len
  panel.cursorVisible = true
  panel.lastBlinkTick = getTicks()
  return true

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

  # Detect paste-like input: multi-character text arriving via TextInput.
  # Route through the bulk paste handler to avoid issues with newlines/large text.
  if text.len > 1:
    return panel.handlePasteViaTextInput(text)

  # Enforce input length limit to prevent pathological input.
  if panel.inputText.len + text.len > MaxInputLen:
    return false
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

    # Send/Stop button: inside input box, bottom-right overflow
    let sendBtnSize = 24
    let inputBoundsW = bounds.w - MessagePadding * 2
    let inputBoundsY = inputY + ToolbarHeight + 6
    let inputBoundsH = InputHeight - ToolbarHeight - 12
    let sendBtnX = bounds.x + MessagePadding + inputBoundsW - sendBtnSize - 4
    let sendBtnY = inputBoundsY + inputBoundsH - sendBtnSize - 4
    let sendBtnBounds = rect(sendBtnX, sendBtnY, sendBtnSize, sendBtnSize)
    if sendBtnBounds.contains(point(e.x, e.y)):
      if panel.isStreaming:
        if panel.onStop != nil:
          panel.onStop()
      else:
        panel.sendCurrentMessage()
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

      # Plan/Build toggle (next to model selector)
      let toggleW = 72
      let toggleH = ToolbarHeight - 2
      let toggleX = modelBtnBounds.x + modelBtnBounds.w + 8
      if rect(toggleX, toolbarY, toggleW, toggleH).contains(point(e.x, e.y)):
        if panel.onPlanModeToggle != nil:
          panel.onPlanModeToggle()
        return true

      # Variants (reasoning-effort) menu, after the Plan/Build toggle
      if panel.showVariants:
        let varX = toggleX + toggleW + 8
        if rect(varX, toolbarY, VariantsButtonWidth, toggleH).contains(point(e.x, e.y)):
          if panel.onVariantsMenu != nil:
            panel.onVariantsMenu(e.x, e.y)
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
    let iconBtnSize = 28
    let iconBtnX = bounds.x + bounds.w - iconBtnSize - 8
    let iconBtnY = bounds.y + (HeaderHeight - iconBtnSize) div 2
    panel.hoverNewChat = rect(iconBtnX, iconBtnY, iconBtnSize, iconBtnSize).contains(point(e.x, e.y))
    panel.hoverAgentMenu = panel.hoverNewChat
    panel.hoverModelMenu = false
    panel.hoverVariants = false
    panel.hoverInput = false
    if panel.showModelControls:
      let inputY = bounds.y + bounds.h - InputHeight
      let toolbarY = inputY + 4
      let modelBtnBounds = rect(bounds.x + MessagePadding, toolbarY, ModelButtonWidth, ToolbarHeight - 2)
      panel.hoverModelMenu = modelBtnBounds.contains(point(e.x, e.y))
      # Plan/Build toggle hover
      let toggleW = 72
      let toggleH = ToolbarHeight - 2
      let toggleX = modelBtnBounds.x + modelBtnBounds.w + 8
      panel.hoverPlanMode = rect(toggleX, toolbarY, toggleW, toggleH).contains(point(e.x, e.y))
      # Variants button hover
      panel.hoverVariants = panel.showVariants and
        rect(toggleX + toggleW + 8, toolbarY, VariantsButtonWidth, toggleH).contains(point(e.x, e.y))
      # Input text area starts below the model toolbar
      panel.hoverInput = e.y >= inputY + ToolbarHeight
    else:
      let inputY = bounds.y + bounds.h - InputHeight
      panel.hoverInput = e.y >= inputY
    # Send button hover (inside input box, bottom-right)
    let sendBtnSize = 24
    let inputBoundsW = bounds.w - MessagePadding * 2
    let inputY2 = bounds.y + bounds.h - InputHeight
    let inputBoundsY = inputY2 + ToolbarHeight + 6
    let inputBoundsH = InputHeight - ToolbarHeight - 12
    let sendBtnX = bounds.x + MessagePadding + inputBoundsW - sendBtnSize - 4
    let sendBtnY = inputBoundsY + inputBoundsH - sendBtnSize - 4
    panel.hoverStop = rect(sendBtnX, sendBtnY, sendBtnSize, sendBtnSize).contains(point(e.x, e.y))
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

    var wrappedLines: seq[string]
    var totalH = 0
    # Thinking section (assistant only): shown as muted, prefixed with a label.
    var thinkingLines: seq[string]
    if not isUser and msg.thinking.len > 0:
      thinkingLines.add("💭 Thinking")
      totalH += fm.lineHeight
      for tl in wrapTextToWidth(msg.thinking, font, maxW):
        thinkingLines.add(tl)
        totalH += fm.lineHeight
      # A blank separator line between thinking and the response.
      thinkingLines.add("")
      totalH += fm.lineHeight
    # Main content (use the shared wrapper that hard-breaks long words).
    if msg.content.len > 0:
      for wl in wrapTextToWidth(msg.content, font, maxW):
        wrappedLines.add(wl)
        totalH += fm.lineHeight
    elif isUser:
      # A user message always has content; guard against empty.
      discard
    else:
      # Assistant message with only thinking and no content yet: show a
      # placeholder so the bubble isn't zero-height while streaming.
      if thinkingLines.len > 0 and msg.content.len == 0 and panel.isStreaming:
        discard  # thinking already gives height
      else:
        wrappedLines.add("")
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
      thinkingLines: thinkingLines,
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
      # Thinking section: rendered first, in muted color.
      for line in bubble.thinkingLines:
        discard font.drawText(bubble.x + MessagePadding, lineY, line, textMuted, color(0, 0, 0, 0))
        lineY += fm.lineHeight
      for line in bubble.wrappedLines:
        discard font.drawText(bubble.x + MessagePadding, lineY, line, bubble.textColor, color(0, 0, 0, 0))
        lineY += fm.lineHeight

  # Streaming indicator: animated braille spinner that cycles over time.
  if panel.isStreaming:
    let indicatorY = messagesY + contentHeight - fm.lineHeight - panel.scrollOffset
    if indicatorY > messagesY and indicatorY < messagesY + messagesH:
      let ticks = getTicks()
      let frame = (ticks div 100) mod StreamingAnimFrames.len
      let spinner = StreamingAnimFrames[frame]
      discard font.drawText(bounds.x + MessagePadding, indicatorY, spinner, textMuted, color(0, 0, 0, 0))

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

    # Plan/Build toggle button (next to model selector)
    let toggleW = 72
    let toggleH = ToolbarHeight - 2
    let toggleX = modelBtnBounds.x + modelBtnBounds.w + 8
    let toggleBounds = rect(toggleX, toolbarY, toggleW, toggleH)
    let toggleBg = if panel.hoverPlanMode: currentTheme.getColor(tcSurfaceHover) else: bg
    fillRect(toggleBounds, toggleBg)
    # Active side highlight (neutral surface, not the blue accent)
    let halfW = toggleW div 2
    let activeBg = currentTheme.getColor(tcSurfaceHover)
    if panel.planMode:
      fillRect(rect(toggleBounds.x, toggleBounds.y, halfW, toggleBounds.h), activeBg)
    else:
      fillRect(rect(toggleBounds.x + halfW, toggleBounds.y, toggleW - halfW, toggleBounds.h), activeBg)
    # Border on top so the (hover) border spans the full toggle, not just one half
    let toggleBorderC = if panel.hoverPlanMode: accentC else: borderC
    fillRect(rect(toggleBounds.x, toggleBounds.y, toggleBounds.w, 1), toggleBorderC)
    fillRect(rect(toggleBounds.x, toggleBounds.y + toggleBounds.h - 1, toggleBounds.w, 1), toggleBorderC)
    fillRect(rect(toggleBounds.x, toggleBounds.y, 1, toggleBounds.h), toggleBorderC)
    fillRect(rect(toggleBounds.x + toggleBounds.w - 1, toggleBounds.y, 1, toggleBounds.h), toggleBorderC)
    # Labels with horizontal padding
    let pad = 4
    let labelY = toggleBounds.y + (toggleBounds.h - fm.lineHeight) div 2
    let planLabel = "Plan"
    let buildLabel = "Build"
    let planLabelW = font.measureText(planLabel).w
    let buildLabelW = font.measureText(buildLabel).w
    let activeLabel = currentTheme.getColor(tcText)
    let leftLabelColor = if panel.planMode: activeLabel else: textMuted
    let rightLabelColor = if panel.planMode: textMuted else: activeLabel
    discard font.drawText(toggleBounds.x + pad + (halfW - pad * 2 - planLabelW) div 2, labelY, planLabel, leftLabelColor, color(0, 0, 0, 0))
    discard font.drawText(toggleBounds.x + halfW + pad + (halfW - pad * 2 - buildLabelW) div 2, labelY, buildLabel, rightLabelColor, color(0, 0, 0, 0))

    # Variants (reasoning-effort) button, after the Plan/Build toggle. Shown only
    # for thinking-capable providers; opens a menu to pick the effort variant.
    if panel.showVariants:
      let varX = toggleBounds.x + toggleW + 8
      let varBounds = rect(varX, toolbarY, VariantsButtonWidth, toggleH)
      let varBg = if panel.hoverVariants: currentTheme.getColor(tcSurfaceHover) else: bg
      fillRect(varBounds, varBg)
      let varBorderC = if panel.hoverVariants: accentC else: borderC
      fillRect(rect(varBounds.x, varBounds.y, varBounds.w, 1), varBorderC)
      fillRect(rect(varBounds.x, varBounds.y + varBounds.h - 1, varBounds.w, 1), varBorderC)
      fillRect(rect(varBounds.x, varBounds.y, 1, varBounds.h), varBorderC)
      fillRect(rect(varBounds.x + varBounds.w - 1, varBounds.y, 1, varBounds.h), varBorderC)
      let effLabel = capitalizeAscii(if panel.reasoningEffort.len > 0: panel.reasoningEffort else: "high")
      # Brain glyph prefix hints this is the thinking control.
      let varText = "◇ " & effLabel
      let varTextW = font.measureText(varText).w
      discard font.drawText(varBounds.x + (VariantsButtonWidth - varTextW) div 2, labelY, varText, textMuted, color(0, 0, 0, 0))

  let inputBounds = rect(
    bounds.x + MessagePadding,
    inputY + ToolbarHeight + 6,
    bounds.w - MessagePadding * 2,
    InputHeight - ToolbarHeight - 12
  )
  # Darker inset field so it (and the send button inside it) stand out from the panel
  fillRect(inputBounds, headerBg)
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

  # Send/stop button: inside input box at bottom-right, overflowing the border
  let sendBtnSize = 24
  let sendBtnX = inputBounds.x + inputBounds.w - sendBtnSize - 4
  let sendBtnY = inputBounds.y + inputBounds.h - sendBtnSize - 4
  let sendBtnBounds = rect(sendBtnX, sendBtnY, sendBtnSize, sendBtnSize)
  let sendBtnBg = if panel.hoverStop: currentTheme.getColor(tcSurfaceHover) else: currentTheme.getColor(tcSurface)
  fillRect(sendBtnBounds, sendBtnBg)
  let sendBtnBorderC = if panel.hoverStop: currentTheme.getColor(tcTextSecondary) else: currentTheme.getColor(tcTextDisabled)
  fillRect(rect(sendBtnBounds.x, sendBtnBounds.y, sendBtnBounds.w, 1), sendBtnBorderC)
  fillRect(rect(sendBtnBounds.x, sendBtnBounds.y + sendBtnBounds.h - 1, sendBtnBounds.w, 1), sendBtnBorderC)
  fillRect(rect(sendBtnBounds.x, sendBtnBounds.y, 1, sendBtnBounds.h), sendBtnBorderC)
  fillRect(rect(sendBtnBounds.x + sendBtnBounds.w - 1, sendBtnBounds.y, 1, sendBtnBounds.h), sendBtnBorderC)
  # Icon: stop when streaming, send when idle
  if panel.isStreaming:
    drawIconCentered(iiStop, sendBtnBounds)
  else:
    drawIconCentered(iiSend, sendBtnBounds)

  # Resize handle at left edge
  let handleX = bounds.x + 2
  let midY = bounds.y + bounds.h div 2
  for i in 0..2:
    fillRect(rect(handleX, midY - 8 + i * 6, 2, 2), borderC)

  # Left border (drawn last so it shows through the header)
  fillRect(rect(bounds.x, bounds.y, 1, bounds.h), borderC)

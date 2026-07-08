## Search/Replace Panel - Sidebar integrated
import std/[os, strutils, nre, tables, locks, typedthreads, sequtils]
import uirelays
import uirelays/[coords, screen, input]
import widgets/synedit
import ../widgets/widgets
import theme, icons
import ../utils/search_engine
import ../core/config

const
  HEADER_HEIGHT = 28
  INPUT_HEIGHT = 26
  TOGGLE_SIZE = 20
  PADDING = 8
  MODE_TAB_H = 22
  ACTION_BTN_H = 24
  FILE_GROUP_H = 22
  RESULT_ITEM_HEIGHT = 22
  SCROLLBAR_WIDTH = 8

type
  SearchMode* = enum
    smCurrentFile
    smWorkspace

  FileMatch* = object
    a*, b*: int            # character positions in current file

  WorkspaceMatch* = object
    path*: string
    line*: int             # 0-based
    col*: int              # 0-based
    matchLen*: int
    preview*: string

  WorkspaceFileGroup* = object
    path*: string
    matchIndices*: seq[int]
    expanded*: bool

  SearchPanel* = object
    font*: Font
    fm*: FontMetrics
    mode*: SearchMode = smCurrentFile
    findText*: string = ""
    replaceText*: string = ""
    caseSensitive*: bool = false
    useRegex*: bool = false
    wholeWord*: bool = false
    isVisible*: bool = false
    # current file search state
    currentMatchIndex*: int = -1
    matches*: seq[FileMatch] = @[]
    # workspace search state
    workspaceMatches*: seq[WorkspaceMatch] = @[]
    workspaceGroups*: seq[WorkspaceFileGroup] = @[]
    workspaceRoot*: string = ""
    workspaceSearchInProgress*: bool = false
    workspaceSearchLock*: Lock
    # async workspace search thread
    workspaceSearchThread*: Thread[WorkspaceSearchArgs]
    workspaceSearchChan*: Channel[string]
    # shared UI state
    focus*: int = 0
    findCursor*: int = 0
    replaceCursor*: int = 0
    resultScroll*: int = 0
    resultMaxScroll*: int = 0
    errorText*: string = ""
    # transient mouse state
    hoveredButton*: int = -1
    hoverInput*: bool = false
    hoveredResult*: int = -1
    hoveredGroupIndex*: int = -1
    # Cached text
    lastText*: string = ""
    lastCacheId*: int = 0
    bounds*: Rect
    # cursor blink
    cursorVisible*: bool = true
    lastBlinkTick*: int = 0
    # search history
    searchHistory*: seq[string] = @[]
    historyIndex*: int = 0
    # callback
    onWorkspaceResultClick*: proc(path: string; line, col: int)

  OnWorkspaceResultClick* = proc(path: string; line, col: int)
    ## Callback type invoked when the user selects a workspace search result.

const markerBg = color(55, 60, 45, 255)
const matchHighlightColor = color(234, 154, 40, 255)

# Exclusions for workspace search
const ExcludedDirs = [".git", "node_modules", ".nimble", "dist", "build", ".cache"]
const ExcludedExts = [".exe", ".dll", ".so", ".dylib", ".png", ".jpg", ".jpeg",
                      ".gif", ".ico", ".woff", ".woff2", ".ttf", ".eot", ".mp3",
                      ".mp4", ".avi", ".mov", ".zip", ".tar", ".gz", ".rar",
                      ".7z", ".pdf", ".doc", ".docx", ".xls", ".xlsx"]


# Initialization

proc isWordChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc newSearchPanel*(font: Font; fm: FontMetrics): SearchPanel =
  result = SearchPanel(
    font: font,
    fm: fm,
    mode: smCurrentFile,
    currentMatchIndex: -1,
    hoveredButton: -1,
    hoveredResult: -1,
    hoveredGroupIndex: -1,
    cursorVisible: true,
    historyIndex: 0
  )
  initLock(result.workspaceSearchLock)
  result.workspaceSearchChan.open()

proc loadSearchState*(panel: var SearchPanel; config: AppConfig) =
  ## Populate search options and initial query from ``config``.
  panel.caseSensitive = config.searchCaseSensitive
  panel.useRegex = config.searchUseRegex
  panel.wholeWord = config.searchWholeWord
  if config.searchHistory.len > 0:
    panel.searchHistory = config.searchHistory
    panel.historyIndex = panel.searchHistory.high
  if config.searchRememberOptions and panel.searchHistory.len > 0:
    panel.findText = panel.searchHistory[^1]
    panel.findCursor = panel.findText.len

proc saveSearchState*(panel: SearchPanel; config: var AppConfig) =
  ## Write current search options and history back to ``config``.
  config.searchCaseSensitive = panel.caseSensitive
  config.searchUseRegex = panel.useRegex
  config.searchWholeWord = panel.wholeWord
  config.searchHistory = panel.searchHistory

proc newSearchPanel*(font: Font; fm: FontMetrics; config: AppConfig): SearchPanel =
  result = newSearchPanel(font, fm)
  loadSearchState(result, config)

proc pushSearchHistory*(panel: var SearchPanel; text: string) =
  ## Add ``text`` to search history, removing duplicates and capping at 20.
  if text.len == 0:
    return
  # Remove existing duplicate so the entry is moved to the end.
  panel.searchHistory.keepItIf(it != text)
  panel.searchHistory.add(text)
  if panel.searchHistory.len > 20:
    panel.searchHistory.delete(0)
  panel.historyIndex = panel.searchHistory.len

proc formatSearchCounter*(panel: SearchPanel): string =
  ## Return the counter string currently shown for the active search mode.
  if panel.errorText.len > 0:
    result = panel.errorText
  elif panel.mode == smCurrentFile:
    result = $(panel.currentMatchIndex + 1) & "/" & $panel.matches.len
  elif panel.mode == smWorkspace:
    result = $panel.workspaceMatches.len & " results"

proc buildWorkspaceGroups(panel: var SearchPanel)

proc parseWorkspaceOutput(panel: var SearchPanel; output: string) =
  ## Parse raw ``path:line:preview`` output into ``workspaceMatches``.
  if output.len == 0:
    panel.workspaceMatches.setLen(0)
    return
  var count = 0
  for line in splitLines(output):
    if line.len < 3: continue
    let colon2 = line.find(":", 2)
    if colon2 < 0: continue
    let relPath = line[0..<colon2]
    if relPath.len == 0: continue
    let fullPath = panel.workspaceRoot / relPath
    let afterColon = line[colon2+1..^1]
    let colon3 = afterColon.find(":")
    if colon3 < 0: continue
    let lineNumStr = afterColon[0..<colon3]
    var lineNum = 0
    try:
      lineNum = parseInt(lineNumStr) - 1
    except ValueError:
      continue
    let preview = afterColon[colon3+1..^1]
    let searchText = if panel.caseSensitive: panel.findText else: panel.findText.toLowerAscii()
    let searchTarget = if panel.caseSensitive: preview else: preview.toLowerAscii()
    let matchStart = searchTarget.find(searchText)
    let matchLen = if matchStart >= 0: searchText.len else: panel.findText.len
    panel.workspaceMatches.add(WorkspaceMatch(
      path: fullPath,
      line: lineNum,
      col: if matchStart >= 0: matchStart else: 0,
      matchLen: matchLen,
      preview: preview
    ))
    inc count
    if count >= 500:
      break

proc pollWorkspaceSearch*(panel: var SearchPanel) =
  ## Check whether the background workspace search has finished. If so,
  ## copy the results, build groups, and clear the in-progress flag.
  if not panel.workspaceSearchInProgress:
    return
  let (avail, output) = panel.workspaceSearchChan.tryRecv()
  if not avail:
    return
  joinThread(panel.workspaceSearchThread)
  withLock(panel.workspaceSearchLock):
    panel.parseWorkspaceOutput(output)
    panel.buildWorkspaceGroups()
    panel.resultScroll = 0
    panel.workspaceSearchInProgress = false
    panel.errorText = if panel.workspaceMatches.len > 0: "" else: "No matches"

# Workspace Group Building

proc buildWorkspaceGroups(panel: var SearchPanel) =
  panel.workspaceGroups.setLen(0)
  var pathToGroup = initTable[string, int]()
  for i, m in panel.workspaceMatches:
    if m.path notin pathToGroup:
      pathToGroup[m.path] = panel.workspaceGroups.len
      panel.workspaceGroups.add(WorkspaceFileGroup(
        path: m.path,
        matchIndices: @[],
        expanded: true
      ))
    let gi = pathToGroup[m.path]
    panel.workspaceGroups[gi].matchIndices.add(i)

# Search Logic

proc findAll*(panel: var SearchPanel; ed: ptr SynEdit) =
  panel.errorText = ""
  panel.matches.setLen(0)
  panel.workspaceMatches.setLen(0)
  panel.workspaceGroups.setLen(0)
  panel.currentMatchIndex = -1
  panel.hoveredResult = -1
  panel.hoveredGroupIndex = -1

  if panel.findText.len == 0:
    if ed != nil:
      ed[].clearMarkers()
    return

  case panel.mode
  of smCurrentFile:
    if ed != nil:
      ed[].clearMarkers()
    let text = if ed != nil: ed[].fullText() else: ""
    if panel.useRegex:
      try:
        let pattern = re(panel.findText)
        for m in text.findIter(pattern):
          let a = m.matchBounds.a
          let b = m.matchBounds.b - 1  # nre uses exclusive end; normalize to inclusive
          if panel.wholeWord:
            let before = if a > 0: text[a-1] else: '\0'
            let after = if b + 1 < text.len: text[b+1] else: '\0'
            if isWordChar(before) or isWordChar(after):
              continue
          panel.matches.add(FileMatch(a: a, b: b))
          if ed != nil:
            ed[].addMarker(a, b, markerBg)
      except RegexError:
        panel.errorText = "Invalid regex"
        return
    else:
      let searchText = if panel.caseSensitive: panel.findText else: panel.findText.toLowerAscii()
      let searchTarget = if panel.caseSensitive: text else: text.toLowerAscii()
      let patLen = searchText.len
      var i = 0
      while i <= searchTarget.len - patLen:
        var j = 0
        while j < patLen and searchTarget[i + j] == searchText[j]:
          inc j
        if j == patLen:
          let endIdx = i + patLen - 1
          if panel.wholeWord:
            let before = if i > 0: searchTarget[i-1] else: '\0'
            let after = if endIdx + 1 < searchTarget.len: searchTarget[endIdx+1] else: '\0'
            if isWordChar(before) or isWordChar(after):
              i += patLen
              continue
          panel.matches.add(FileMatch(a: i, b: endIdx))
          if ed != nil:
            ed[].addMarker(i, endIdx, markerBg)
          i += patLen
        else:
          inc i
    panel.currentMatchIndex = if panel.matches.len > 0: 0 else: -1
    if panel.currentMatchIndex >= 0 and ed != nil:
      ed[].gotoPos(panel.matches[panel.currentMatchIndex].a)

  of smWorkspace:
    if panel.workspaceRoot.len == 0 or not dirExists(panel.workspaceRoot):
      panel.errorText = "No workspace open"
      return

    if panel.workspaceSearchInProgress:
      return

    withLock(panel.workspaceSearchLock):
      panel.workspaceSearchInProgress = true
      panel.errorText = "Searching..."
      panel.workspaceMatches.setLen(0)
      panel.workspaceGroups.setLen(0)

    let args = WorkspaceSearchArgs(
      findText: panel.findText,
      workspaceRoot: panel.workspaceRoot,
      caseSensitive: panel.caseSensitive,
      useRegex: panel.useRegex,
      excludedDirs: @ExcludedDirs,
      excludedExts: @ExcludedExts,
      chan: addr panel.workspaceSearchChan
    )
    createThread(panel.workspaceSearchThread, workspaceSearchThreadProc, args)

proc cycleSearchHistory*(panel: var SearchPanel; ed: ptr SynEdit; direction: int) =
  ## Replace ``findText`` with the previous (direction < 0) or next
  ## (direction > 0) history entry and rerun the search.
  if panel.searchHistory.len == 0:
    return
  var idx = panel.historyIndex + direction
  idx = clamp(idx, 0, panel.searchHistory.high)
  panel.historyIndex = idx
  panel.findText = panel.searchHistory[idx]
  panel.findCursor = panel.findText.len
  panel.findAll(ed)

proc findNext*(panel: var SearchPanel; ed: ptr SynEdit) =
  if panel.mode != smCurrentFile: return
  if panel.matches.len == 0:
    panel.findAll(ed)
  if panel.matches.len == 0:
    return
  panel.currentMatchIndex = (panel.currentMatchIndex + 1) mod panel.matches.len
  if ed != nil:
    ed[].gotoPos(panel.matches[panel.currentMatchIndex].a)

proc findPrevious*(panel: var SearchPanel; ed: ptr SynEdit) =
  if panel.mode != smCurrentFile: return
  if panel.matches.len == 0:
    panel.findAll(ed)
  if panel.matches.len == 0:
    return
  panel.currentMatchIndex = (panel.currentMatchIndex - 1 + panel.matches.len) mod panel.matches.len
  if ed != nil:
    ed[].gotoPos(panel.matches[panel.currentMatchIndex].a)

# Replace Logic (current file only)

proc replaceAll*(panel: var SearchPanel; ed: ptr SynEdit): int =
  ## Replace all matches in the current file and return the number of replacements made.
  if panel.mode != smCurrentFile: return 0
  if ed == nil or panel.matches.len == 0:
    return 0
  result = panel.matches.len
  # Rebuild text from matches in reverse
  var text = ed[].fullText()
  for i in countdown(panel.matches.high, 0):
    let m = panel.matches[i]
    text = text[0 ..< m.a] & panel.replaceText & text[(m.b + 1) .. ^1]
  ed[].setText(text)
  ed[].markChanged()
  panel.findAll(ed)

proc replaceCurrent*(panel: var SearchPanel; ed: ptr SynEdit): bool =
  if panel.mode != smCurrentFile: return false
  if ed == nil or panel.currentMatchIndex < 0 or panel.currentMatchIndex >= panel.matches.len:
    return false
  let m = panel.matches[panel.currentMatchIndex]
  var text = ed[].fullText()
  text = text[0 ..< m.a] & panel.replaceText & text[(m.b + 1) .. ^1]
  ed[].setText(text)
  ed[].markChanged()
  let newPos = m.a + panel.replaceText.len
  ed[].gotoPos(newPos)
  panel.findAll(ed)
  for i, match in panel.matches:
    if match.a >= newPos:
      panel.currentMatchIndex = i
      ed[].gotoPos(match.a)
      return true
  false

# Show / Hide

proc show*(panel: var SearchPanel; ed: ptr SynEdit; focusReplace: bool = false) =
  panel.isVisible = true
  panel.focus = if focusReplace: 1 else: 0
  panel.currentMatchIndex = -1
  panel.resultScroll = 0
  panel.cursorVisible = true
  panel.lastBlinkTick = getTicks()
  if panel.findText.len > 0:
    panel.findAll(ed)

proc hide*(panel: var SearchPanel; ed: ptr SynEdit) =
  panel.isVisible = false
  panel.focus = -1
  if ed != nil:
    ed[].clearMarkers()
  panel.matches.setLen(0)
  panel.workspaceMatches.setLen(0)
  panel.workspaceGroups.setLen(0)
  panel.currentMatchIndex = -1
  panel.resultScroll = 0

# Helpers

proc lineColAtPos(text: string; pos: int): tuple[line, col: int] =
  var line = 0
  var col = 0
  for i in 0 ..< min(pos, text.len):
    if text[i] == '\L':
      inc line
      col = 0
    else:
      inc col
  return (line, col)

proc truncateTextToWidth(text: string; font: Font; maxWidth: int): string =
  result = text
  while result.len > 0 and measureText(font, result).w > maxWidth:
    result.setLen(result.len - 1)

# Input Handling

proc handleInput*(panel: var SearchPanel; ed: ptr SynEdit; e: Event): bool =
  if not panel.isVisible:
    return false

  case e.kind
  of KeyDownEvent:
    case e.key
    of KeyEsc:
      panel.hide(ed)
      return true
    of KeyUp:
      if AltPressed in e.mods and panel.focus == 0:
        panel.cycleSearchHistory(ed, -1)
        return true
      return false
    of KeyDown:
      if AltPressed in e.mods and panel.focus == 0:
        panel.cycleSearchHistory(ed, 1)
        return true
      return false
    of KeyV:
      let pasteMod = when defined(macosx): GuiPressed else: CtrlPressed
      if pasteMod in e.mods:
        let text = getClipboardText()
        if text.len > 0 and panel.focus >= 0:
          if panel.focus == 0:
            panel.findText.add(text)
            panel.pushSearchHistory(panel.findText)
            panel.findAll(ed)
          else:
            panel.replaceText.add(text)
          panel.cursorVisible = true
          panel.lastBlinkTick = getTicks()
          return true
      return false
    of KeyEnter:
      if panel.focus == 0:
        panel.pushSearchHistory(panel.findText)
      if panel.mode == smCurrentFile:
        if ShiftPressed in e.mods:
          panel.findPrevious(ed)
        else:
          panel.findNext(ed)
      else:
        panel.findAll(ed)
      return true
    of KeyTab:
      if panel.mode == smCurrentFile:
        if panel.focus < 0:
          panel.focus = 0
        else:
          panel.focus = if panel.focus == 0: 1 else: 0
      else:
        panel.focus = 0
      return true
    of KeyBackspace:
      if panel.focus >= 0:
        if panel.focus == 0:
          if panel.findText.len > 0:
            let cp = panel.findCursor
            if cp > 0 and cp <= panel.findText.len:
              panel.findText = panel.findText[0..<cp-1] & panel.findText[cp..^1]
              panel.findCursor = cp - 1
            else:
              panel.findText.setLen(panel.findText.len - 1)
              panel.findCursor = panel.findText.len
            panel.findAll(ed)
        else:
          if panel.replaceText.len > 0:
            let cp = panel.replaceCursor
            if cp > 0 and cp <= panel.replaceText.len:
              panel.replaceText = panel.replaceText[0..<cp-1] & panel.replaceText[cp..^1]
              panel.replaceCursor = cp - 1
            else:
              panel.replaceText.setLen(panel.replaceText.len - 1)
              panel.replaceCursor = panel.replaceText.len
        panel.cursorVisible = true
        panel.lastBlinkTick = getTicks()
        return true
      return false
    of KeyLeft:
      if panel.focus >= 0:
        if panel.focus == 0:
          panel.findCursor = max(0, panel.findCursor - 1)
        else:
          panel.replaceCursor = max(0, panel.replaceCursor - 1)
        panel.cursorVisible = true
        panel.lastBlinkTick = getTicks()
        return true
      return false
    of KeyRight:
      if panel.focus >= 0:
        if panel.focus == 0:
          panel.findCursor = min(panel.findText.len, panel.findCursor + 1)
        else:
          panel.replaceCursor = min(panel.replaceText.len, panel.replaceCursor + 1)
        panel.cursorVisible = true
        panel.lastBlinkTick = getTicks()
        return true
      return false
    else:
      return false
  of TextInputEvent:
    if panel.focus >= 0:
      var s = ""
      for c in e.text:
        if c == '\0': break
        s.add(c)
      if panel.focus == 0:
        let cp = panel.findCursor
        panel.findText = panel.findText[0..<cp] & s & panel.findText[cp..^1]
        panel.findCursor = cp + s.len
        panel.pushSearchHistory(panel.findText)
        panel.findAll(ed)
      else:
        let cp = panel.replaceCursor
        panel.replaceText = panel.replaceText[0..<cp] & s & panel.replaceText[cp..^1]
        panel.replaceCursor = cp + s.len
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
    return false
  else:
    discard
  false

# Mouse Handling

proc handleMouse*(panel: var SearchPanel; ed: ptr SynEdit; e: Event; bounds: Rect;
                  onNotification: proc(msg: string) = nil): bool =
  if not panel.isVisible:
    return false

  if e.kind == MouseWheelEvent:
    panel.resultScroll = clamp(panel.resultScroll - e.y * RESULT_ITEM_HEIGHT, 0, panel.resultMaxScroll)
    return true

  let mx = e.x
  let my = e.y
  if not bounds.contains(point(mx, my)):
    panel.hoveredButton = -1
    panel.hoverInput = false
    panel.hoveredResult = -1
    panel.hoveredGroupIndex = -1
    return false

  let relX = mx - bounds.x
  let relY = my - bounds.y

  # Layout constants
  let inputW = bounds.w - PADDING * 2

  var y = PADDING

  # Header
  let headerY = y
  y += HEADER_HEIGHT

  # Mode tabs
  let modeY = y
  let fileTabW = measureText(panel.font, "File").w
  let tabSpacing = 16
  let wsTabW = measureText(panel.font, "Workspace").w
  let wsTabX = int(PADDING + fileTabW + tabSpacing)
  y += MODE_TAB_H + 4

  # Find input
  let findY = y
  y += INPUT_HEIGHT + 4

  # Replace input (always shown in File mode)
  var replaceY = 0
  if panel.mode == smCurrentFile:
    replaceY = y
    y += INPUT_HEIGHT + 4

  # Action row
  let actionY = y
  y += ACTION_BTN_H + 6

  # Divider
  let dividerY = y

  # Results
  let resultsY = dividerY + 8

  panel.hoveredButton = -1
  panel.hoverInput = false
  panel.hoveredResult = -1
  panel.hoveredGroupIndex = -1

  # Header hit-test
  if relY >= headerY and relY < headerY + HEADER_HEIGHT:
    # Refresh button
    let refreshX = bounds.w - PADDING - TOGGLE_SIZE
    if relX >= refreshX and relX < refreshX + TOGGLE_SIZE:
      panel.hoveredButton = 11
      if e.kind == MouseDownEvent:
        panel.pushSearchHistory(panel.findText)
        panel.findAll(ed)
      return true
    # Clear results button
    let clearX = refreshX - TOGGLE_SIZE - 4
    if relX >= clearX and relX < clearX + TOGGLE_SIZE:
      panel.hoveredButton = 12
      if e.kind == MouseDownEvent:
        panel.findText = ""
        panel.findAll(ed)
      return true
    return false

  # Mode tab hit-test
  if relY >= modeY and relY < modeY + MODE_TAB_H:
    if relX >= PADDING and relX < PADDING + fileTabW:
      panel.hoveredButton = 9
      if e.kind == MouseDownEvent:
        panel.mode = smCurrentFile
        panel.findAll(ed)
      return true
    elif relX >= wsTabX and relX < wsTabX + wsTabW:
      panel.hoveredButton = 10
      if e.kind == MouseDownEvent:
        panel.mode = smWorkspace
        panel.findAll(ed)
      return true

  # Find input hit-test
  if relY >= findY and relY < findY + INPUT_HEIGHT:
    let toggleAreaW = TOGGLE_SIZE * 3 + 8
    let textAreaW = inputW - toggleAreaW - 30
    # Text area - click to position cursor
    if relX >= PADDING + 24 and relX < PADDING + 24 + textAreaW:
      panel.hoverInput = true
      panel.focus = 0
      if e.kind == MouseDownEvent:
        let relClickX = relX - (PADDING + 24)
        var newPos = panel.findText.len
        let textLen = panel.findText.len
        for i in 0 ..< textLen:
          let charW = measureText(panel.font, panel.findText[0..<i+1]).w
          if charW > relClickX:
            newPos = i
            break
          if i == textLen - 1:
            newPos = textLen
        panel.findCursor = newPos
      return true
    # Clear button
    if panel.findText.len > 0 and relX >= inputW - toggleAreaW - 22 and relX < inputW - toggleAreaW - 2:
      panel.hoveredButton = 5
      if e.kind == MouseDownEvent:
        panel.findText = ""
        panel.findAll(ed)
      return true
    # Toggles
    var tx = bounds.w - PADDING - TOGGLE_SIZE
    # Whole word
    if relX >= tx and relX < tx + TOGGLE_SIZE:
      panel.hoveredButton = 8
      if e.kind == MouseDownEvent:
        panel.wholeWord = not panel.wholeWord
        if panel.findText.len > 0:
          panel.findAll(ed)
      return true
    tx -= TOGGLE_SIZE + 2
    # Regex
    if relX >= tx and relX < tx + TOGGLE_SIZE:
      panel.hoveredButton = 7
      if e.kind == MouseDownEvent:
        panel.useRegex = not panel.useRegex
        if panel.findText.len > 0:
          panel.findAll(ed)
      return true
    tx -= TOGGLE_SIZE + 2
    # Case sensitive
    if relX >= tx and relX < tx + TOGGLE_SIZE:
      panel.hoveredButton = 6
      if e.kind == MouseDownEvent:
        panel.caseSensitive = not panel.caseSensitive
        if panel.findText.len > 0:
          panel.findAll(ed)
      return true

  # Replace input hit-test
  if panel.mode == smCurrentFile and relY >= replaceY and relY < replaceY + INPUT_HEIGHT:
    let textAreaW = inputW - 8
    if relX >= PADDING + 4 and relX < PADDING + 4 + textAreaW:
      panel.hoverInput = true
      panel.focus = 1
      if e.kind == MouseDownEvent:
        let relClickX = relX - (PADDING + 4)
        var newPos = panel.replaceText.len
        let textLen = panel.replaceText.len
        for i in 0 ..< textLen:
          let charW = measureText(panel.font, panel.replaceText[0..<i+1]).w
          if charW > relClickX:
            newPos = i
            break
          if i == textLen - 1:
            newPos = textLen
        panel.replaceCursor = newPos
      return true

  # Action row hit-test
  if relY >= actionY and relY < actionY + ACTION_BTN_H:
    var btnX = PADDING

    # Prev
    if relX >= btnX and relX < btnX + TOGGLE_SIZE:
      panel.hoveredButton = 0
      if e.kind == MouseDownEvent:
        panel.pushSearchHistory(panel.findText)
        if panel.mode == smCurrentFile:
          panel.findPrevious(ed)
        else:
          panel.findAll(ed)
      return true
    btnX += TOGGLE_SIZE + 4

    # Next
    if relX >= btnX and relX < btnX + TOGGLE_SIZE:
      panel.hoveredButton = 1
      if e.kind == MouseDownEvent:
        panel.pushSearchHistory(panel.findText)
        if panel.mode == smCurrentFile:
          panel.findNext(ed)
        else:
          panel.findAll(ed)
      return true
    btnX += TOGGLE_SIZE + 4

    if panel.mode == smCurrentFile:
      # Replace button
      let repBtnW = 52
      if relX >= btnX and relX < btnX + repBtnW:
        panel.hoveredButton = 2
        if e.kind == MouseDownEvent:
          discard panel.replaceCurrent(ed)
        return true
      btnX += repBtnW + 4

      # Replace All button
      let repAllBtnW = 66
      if relX >= btnX and relX < btnX + repAllBtnW:
        panel.hoveredButton = 3
        if e.kind == MouseDownEvent:
          let count = panel.replaceAll(ed)
          if count > 0 and onNotification != nil:
            onNotification("Replaced " & $count & " occurrence" & (if count > 1: "s" else: ""))
        return true
      btnX += repAllBtnW + 4

  # Results hit-test
  if relY >= resultsY:
    case panel.mode
    of smCurrentFile:
      if panel.matches.len > 0:
        let itemIdx = (relY - resultsY + panel.resultScroll) div RESULT_ITEM_HEIGHT
        if itemIdx >= 0 and itemIdx < panel.matches.len:
          if e.kind == MouseDownEvent:
            panel.currentMatchIndex = itemIdx
            if ed != nil:
              ed[].gotoPos(panel.matches[itemIdx].a)
          return true
    of smWorkspace:
      if panel.workspaceGroups.len > 0:
        var sy = resultsY - panel.resultScroll
        for gi, group in panel.workspaceGroups:
          # Group header
          if relY >= sy and relY < sy + FILE_GROUP_H:
            panel.hoveredGroupIndex = gi
            if e.kind == MouseDownEvent:
              panel.workspaceGroups[gi].expanded = not panel.workspaceGroups[gi].expanded
            return true
          sy += FILE_GROUP_H
          if group.expanded:
            for mi in group.matchIndices:
              if relY >= sy and relY < sy + RESULT_ITEM_HEIGHT:
                panel.hoveredResult = mi
                if e.kind == MouseDownEvent:
                  let m = panel.workspaceMatches[mi]
                  if panel.onWorkspaceResultClick != nil:
                    panel.onWorkspaceResultClick(m.path, m.line, m.col)
                return true
              sy += RESULT_ITEM_HEIGHT

  false

# Rendering Helpers

proc drawMatchText(font: Font; x, y: int; text: string; matchStart, matchLen: int;
                   textC, matchC, bg: Color) =
  # Draw text with highlighted match
  if matchStart < 0 or matchLen <= 0 or matchStart >= text.len:
    discard drawText(font, x, y, text, textC, bg)
    return
  let before = text[0 ..< matchStart]
  let mat = text[matchStart ..< min(matchStart + matchLen, text.len)]
  let after = if matchStart + matchLen < text.len: text[(matchStart + matchLen) .. ^1] else: ""

  var cx = x
  if before.len > 0:
    discard drawText(font, cx, y, before, textC, bg)
    cx += measureText(font, before).w
  if mat.len > 0:
    discard drawText(font, cx, y, mat, matchC, bg)
    cx += measureText(font, mat).w
  if after.len > 0:
    discard drawText(font, cx, y, after, textC, bg)

# Rendering

proc render*(panel: var SearchPanel; ed: ptr SynEdit; bounds: Rect) =
  panel.bounds = bounds
  let
    bg = currentTheme.getColor(tcBackground)
    surface = currentTheme.getColor(tcSurface)
    borderC = currentTheme.getColor(tcBorder)
    textC = currentTheme.getColor(tcText)
    textSecondary = currentTheme.getColor(tcTextSecondary)
    accent = currentTheme.getColor(tcAccent)
    bgHover = currentTheme.getColor(tcSurfaceHover)
    errorColor = currentTheme.getColor(tcError)

  if not panel.isVisible:
    return

  # Cursor blink
  var blink = false
  let ticks = getTicks()
  if ticks - panel.lastBlinkTick > 500:
    panel.cursorVisible = not panel.cursorVisible
    panel.lastBlinkTick = ticks
  blink = panel.cursorVisible

  # Background
  fillRect(bounds, surface)
  fillRect(rect(bounds.x + bounds.w - 1, bounds.y, 1, bounds.h), borderC)

  var y = bounds.y + PADDING

  # Header
  let headerY = y
  let headerTextH = measureText(panel.font, "SEARCH").h
  discard drawText(panel.font, bounds.x + PADDING, headerY + (HEADER_HEIGHT - headerTextH) div 2,
                   "SEARCH", textC, surface)

  # Action buttons on right
  var actionX = bounds.x + bounds.w - PADDING - TOGGLE_SIZE
  # Clear results
  let clearBounds = rect(actionX, headerY + (HEADER_HEIGHT - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE)
  if panel.hoveredButton == 12:
    fillRect(clearBounds, bgHover)
  drawIconCentered(iiClose, clearBounds)
  actionX -= TOGGLE_SIZE + 4

  # Refresh
  let refreshBounds = rect(actionX, headerY + (HEADER_HEIGHT - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE)
  if panel.hoveredButton == 11:
    fillRect(refreshBounds, bgHover)
  drawIconCentered(iiRefresh, refreshBounds)

  y += HEADER_HEIGHT

  # Mode tabs
  let tabSpacing = 16
  let fileTabW = measureText(panel.font, "File").w
  let wsTabW = measureText(panel.font, "Workspace").w

  let fileTabX = bounds.x + PADDING
  let fileTabColor = if panel.mode == smCurrentFile: textC else: textSecondary
  discard drawText(panel.font, fileTabX, y, "File", fileTabColor, surface)
  if panel.hoveredButton == 9 and panel.mode != smCurrentFile:
    fillRect(rect(fileTabX, y + MODE_TAB_H - 2, fileTabW, 2), bgHover)
  elif panel.mode == smCurrentFile:
    fillRect(rect(fileTabX, y + MODE_TAB_H - 2, fileTabW, 2), accent)

  let wsTabX = fileTabX + fileTabW + tabSpacing
  let wsTabColor = if panel.mode == smWorkspace: textC else: textSecondary
  discard drawText(panel.font, wsTabX, y, "Workspace", wsTabColor, surface)
  if panel.hoveredButton == 10 and panel.mode != smWorkspace:
    fillRect(rect(wsTabX, y + MODE_TAB_H - 2, wsTabW, 2), bgHover)
  elif panel.mode == smWorkspace:
    fillRect(rect(wsTabX, y + MODE_TAB_H - 2, wsTabW, 2), accent)

  y += MODE_TAB_H + 4

  let inputW = bounds.w - PADDING * 2

  # Find input using widget component
  let findBounds = rect(bounds.x + PADDING, y, inputW, INPUT_HEIGHT)
  var findBox = InputBox(text: panel.findText, placeholder: "Find", icon: iiSearch,
                       focused: panel.focus == 0, showClear: panel.findText.len > 0,
                       cursorPos: panel.findCursor)
  let hoveredClear = panel.hoveredButton == 5
  findBox.render(panel.font, findBounds, hoveredClear, blink, panel.findCursor, accent, bg, borderC, textC, textSecondary)

  # Toggles using widget component
  var toggleX = findBounds.x + findBounds.w - PADDING - TOGGLE_SIZE + 4
  var wholeWordToggle = Toggle(active: panel.wholeWord)
  wholeWordToggle.render(panel.font, rect(toggleX, findBounds.y + (INPUT_HEIGHT - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE),
                        "W", panel.hoveredButton == 8, accent, bg, bgHover, textC)
  toggleX -= TOGGLE_SIZE + 2

  var regexToggle = Toggle(active: panel.useRegex)
  regexToggle.render(panel.font, rect(toggleX, findBounds.y + (INPUT_HEIGHT - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE),
                    ".*", panel.hoveredButton == 7, accent, bg, bgHover, textC)
  toggleX -= TOGGLE_SIZE + 2

  var caseToggle = Toggle(active: panel.caseSensitive)
  caseToggle.render(panel.font, rect(toggleX, findBounds.y + (INPUT_HEIGHT - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE),
                  "Aa", panel.hoveredButton == 6, accent, bg, bgHover, textC)

  y += INPUT_HEIGHT + 4

  # Replace input using widget component
  if panel.mode == smCurrentFile:
    let replaceBounds = rect(bounds.x + PADDING, y, inputW, INPUT_HEIGHT)
    var replaceBox = InputBox(text: panel.replaceText, placeholder: "Replace", icon: iiNone,
                            focused: panel.focus == 1, showClear: false,
                            cursorPos: panel.replaceCursor)
    replaceBox.render(panel.font, replaceBounds, false, blink, panel.replaceCursor, accent, bg, borderC, textC, textSecondary)
    y += INPUT_HEIGHT + 4

  # Action row using widget components
  let actionY = y
  var btnX = bounds.x + PADDING

  # Prev button
  var prevBtn = newIconButton(iiArrowUp)
  let prevBounds = rect(btnX, actionY + (ACTION_BTN_H - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE)
  prevBtn.render(prevBounds, panel.hoveredButton == 0, bgHover)
  btnX += TOGGLE_SIZE + 4

  # Next button
  var nextBtn = newIconButton(iiArrowDown)
  let nextBounds = rect(btnX, actionY + (ACTION_BTN_H - TOGGLE_SIZE) div 2, TOGGLE_SIZE, TOGGLE_SIZE)
  nextBtn.render(nextBounds, panel.hoveredButton == 1, bgHover)
  btnX += TOGGLE_SIZE + 4

  if panel.mode == smCurrentFile:
    # Replace button
    var replaceBtn = newActionButton("Replace")
    let repBtnBounds = rect(btnX, actionY + (ACTION_BTN_H - TOGGLE_SIZE) div 2, 52, TOGGLE_SIZE)
    replaceBtn.render(panel.font, repBtnBounds, panel.hoveredButton == 2, surface, bgHover, textC)
    btnX += 52 + 4

    # Replace All button
    var replaceAllBtn = newActionButton("Replace All")
    let repAllBounds = rect(btnX, actionY + (ACTION_BTN_H - TOGGLE_SIZE) div 2, 66, TOGGLE_SIZE)
    replaceAllBtn.render(panel.font, repAllBounds, panel.hoveredButton == 3, surface, bgHover, textC)
    btnX += 66 + 4

  # Match count / error
  let countText = panel.formatSearchCounter()
  if countText.len > 0:
    let countW = measureText(panel.font, countText).w
    let countX = max(bounds.x + bounds.w - PADDING - countW, btnX + 8)
    let countTextH = measureText(panel.font, countText).h
    let countColor = if panel.errorText.len > 0: errorColor else: textSecondary
    # Erase the area behind the counter so it remains readable over buttons.
    fillRect(rect(countX - 2, actionY + (ACTION_BTN_H - countTextH) div 2 - 1,
                  countW + 4, countTextH + 2), surface)
    discard drawText(panel.font, countX, actionY + (ACTION_BTN_H - countTextH) div 2,
                     countText, countColor, surface)

  y += ACTION_BTN_H + 6

  # Divider
  let dividerY = y
  fillRect(rect(bounds.x + PADDING, dividerY, bounds.w - PADDING * 2, 1), borderC)

  # Results List
  let resultsY = dividerY + 7
  let resultsH = bounds.y + bounds.h - resultsY
  if resultsH > 0:
    saveState()
    setClipRect(rect(bounds.x, resultsY, bounds.w, resultsH))

    var itemY = resultsY - panel.resultScroll

    case panel.mode
    of smCurrentFile:
      panel.resultMaxScroll = max(0, panel.matches.len * RESULT_ITEM_HEIGHT - resultsH)
      panel.resultScroll = min(panel.resultScroll, panel.resultMaxScroll)

      var text = ""
      if ed != nil:
        text = ed[].fullText()
        if ed[].cacheId == panel.lastCacheId and panel.lastText.len > 0:
          text = panel.lastText
        else:
          panel.lastCacheId = ed[].cacheId
          panel.lastText = text

      for i, m in panel.matches:
        let rowBounds = rect(bounds.x, itemY, bounds.w, RESULT_ITEM_HEIGHT)
        if rowBounds.y + rowBounds.h > resultsY and rowBounds.y < resultsY + resultsH:
          if i == panel.currentMatchIndex:
            fillRect(rowBounds, accent)

          let (lineNum, col) = lineColAtPos(text, m.a)
          var lineStart = m.a - col
          if lineStart < 0: lineStart = 0
          var lineEnd = lineStart
          while lineEnd < text.len and text[lineEnd] != '\L': inc lineEnd
          let lineContent = text[lineStart ..< lineEnd]
          let lineNumStr = $(lineNum + 1) & ": "
          let numW = measureText(panel.font, lineNumStr).w
          let rowBg = if i == panel.currentMatchIndex: accent else: surface
          discard drawText(panel.font, bounds.x + PADDING, itemY + 4, lineNumStr, textSecondary, rowBg)

          let maxTextW = bounds.w - PADDING * 2 - numW - SCROLLBAR_WIDTH
          # Highlight match
          let matchColInLine = m.a - lineStart
          let matchLenInLine = m.b - m.a + 1
          var displayText = lineContent
          displayText = truncateTextToWidth(displayText, panel.font, maxTextW)
          # Adjust for truncation
          var hlStart = matchColInLine
          var hlLen = matchLenInLine
          if hlStart + hlLen > displayText.len:
            hlLen = displayText.len - hlStart
          if hlStart < 0: hlStart = 0
          drawMatchText(panel.font, bounds.x + PADDING + numW, itemY + 4,
                        displayText, hlStart, hlLen, textC, matchHighlightColor, rowBg)
        itemY += RESULT_ITEM_HEIGHT

    of smWorkspace:
      # Calculate scroll height
      var totalContentH = 0
      for group in panel.workspaceGroups:
        totalContentH += FILE_GROUP_H
        if group.expanded:
          totalContentH += group.matchIndices.len * RESULT_ITEM_HEIGHT
      panel.resultMaxScroll = max(0, totalContentH - resultsH)
      panel.resultScroll = min(panel.resultScroll, panel.resultMaxScroll)

      for gi, group in panel.workspaceGroups:
        # File group header
        let groupBounds = rect(bounds.x, itemY, bounds.w, FILE_GROUP_H)
        if groupBounds.y + groupBounds.h > resultsY and groupBounds.y < resultsY + resultsH:
          if gi == panel.hoveredGroupIndex:
            fillRect(groupBounds, bgHover)

          let arrowIcon = if group.expanded: iiChevronDown else: iiChevronRight
          drawIcon(arrowIcon, bounds.x + PADDING, itemY + (FILE_GROUP_H - 16) div 2)

          let fileName = extractFilename(group.path)
          let rel = relativePath(group.path, panel.workspaceRoot)
          let displayPath = if rel.len > 0 and rel.len < group.path.len: rel else: fileName
          let groupText = displayPath & " (" & $group.matchIndices.len & ")"
          let groupTextH = measureText(panel.font, groupText).h
          discard drawText(panel.font, bounds.x + PADDING + 20, itemY + (FILE_GROUP_H - groupTextH) div 2,
                           groupText, textC, if gi == panel.hoveredGroupIndex: bgHover else: surface)
        itemY += FILE_GROUP_H

        if group.expanded:
          for mi in group.matchIndices:
            let m = panel.workspaceMatches[mi]
            let rowBounds = rect(bounds.x, itemY, bounds.w, RESULT_ITEM_HEIGHT)
            if rowBounds.y + rowBounds.h > resultsY and rowBounds.y < resultsY + resultsH:
              if mi == panel.hoveredResult:
                fillRect(rowBounds, bgHover)

              let lineNumStr = $(m.line + 1) & ": "
              let numW = measureText(panel.font, lineNumStr).w
              let rowBg = if mi == panel.hoveredResult: bgHover else: surface
              let contentX = bounds.x + PADDING + 20
              discard drawText(panel.font, contentX, itemY + 4, lineNumStr, textSecondary, rowBg)

              let maxPreviewW = bounds.w - PADDING * 2 - 20 - numW - SCROLLBAR_WIDTH
              var displayPreview = m.preview
              displayPreview = truncateTextToWidth(displayPreview, panel.font, maxPreviewW)
              # Highlight match
              let hlStart = m.col
              var hlLen = m.matchLen
              if hlStart + hlLen > displayPreview.len:
                hlLen = displayPreview.len - hlStart
              if hlStart < 0: hlLen = 0
              drawMatchText(panel.font, contentX + numW, itemY + 4,
                            displayPreview, hlStart, hlLen, textC, matchHighlightColor, rowBg)
            itemY += RESULT_ITEM_HEIGHT

    # Scrollbar
    let totalItems = case panel.mode
      of smCurrentFile: panel.matches.len
      of smWorkspace:
        var n = 0
        for g in panel.workspaceGroups:
          n += 1
          if g.expanded: n += g.matchIndices.len
        n
    if panel.resultMaxScroll > 0 and totalItems > 0:
      let trackY = resultsY
      let trackH = resultsH
      let scrollX = bounds.x + bounds.w - SCROLLBAR_WIDTH
      fillRect(rect(scrollX, trackY, SCROLLBAR_WIDTH, trackH), bg)
      let totalH = totalItems * RESULT_ITEM_HEIGHT
      let gripH = max(20, int(trackH.float * trackH.float / max(1, totalH).float))
      let gripY = trackY + int(panel.resultScroll.float / panel.resultMaxScroll.float * (trackH - gripH).float)
      fillRect(rect(scrollX + 2, gripY, SCROLLBAR_WIDTH - 4, gripH), textSecondary)

    restoreState()

# Bottom results panel renderer

proc renderBottomResults*(panel: var SearchPanel; font: Font; bounds: Rect;
                          onClick: OnWorkspaceResultClick) =
  ## Render workspace search results in a wide bottom-panel area with more
  ## context per match. The supplied ``onClick`` callback is stored on the
  ## panel for callers that wire up mouse selection later.
  if onClick != nil:
    panel.onWorkspaceResultClick = onClick

  let
    bg = currentTheme.getColor(tcBackground)
    surface = currentTheme.getColor(tcSurface)
    borderC = currentTheme.getColor(tcBorder)
    textC = currentTheme.getColor(tcText)
    textSecondary = currentTheme.getColor(tcTextSecondary)

  fillRect(bounds, surface)
  fillRect(rect(bounds.x, bounds.y, bounds.w, 1), borderC)

  var itemY = bounds.y + PADDING
  saveState()
  setClipRect(bounds)

  for group in panel.workspaceGroups:
    if itemY > bounds.y + bounds.h:
      break

    # File header with more context than the sidebar view.
    let rel = relativePath(group.path, panel.workspaceRoot)
    let fileName = extractFilename(group.path)
    let headerText = if rel.len > 0: rel else: fileName
    let headerH = max(FILE_GROUP_H, measureText(font, headerText).h + 6)
    let groupBounds = rect(bounds.x, itemY, bounds.w, headerH)
    fillRect(groupBounds, bg)
    drawIcon(iiChevronDown, bounds.x + PADDING, itemY + (headerH - 16) div 2)
    discard drawText(font, bounds.x + PADDING + 20, itemY + 3, headerText, textC, bg)
    itemY += headerH

    if itemY > bounds.y + bounds.h:
      break

    for mi in group.matchIndices:
      let m = panel.workspaceMatches[mi]
      let rowBounds = rect(bounds.x, itemY, bounds.w, RESULT_ITEM_HEIGHT)
      if rowBounds.y >= bounds.y + bounds.h:
        break

      let rowBg = surface
      let metaText = "  line " & $(m.line + 1) & ", col " & $(m.col + 1) & "  "
      let metaW = measureText(font, metaText).w
      let contentX = bounds.x + PADDING + 20

      discard drawText(font, contentX, itemY + 4, metaText, textSecondary, rowBg)

      let maxPreviewW = bounds.w - PADDING * 2 - 20 - metaW - SCROLLBAR_WIDTH
      var displayPreview = m.preview
      displayPreview = truncateTextToWidth(displayPreview, font, maxPreviewW)
      var hlStart = m.col
      var hlLen = m.matchLen
      if hlStart + hlLen > displayPreview.len:
        hlLen = displayPreview.len - hlStart
      if hlStart < 0: hlLen = 0
      drawMatchText(font, contentX + metaW, itemY + 4,
                    displayPreview, hlStart, hlLen, textC, matchHighlightColor, rowBg)
      itemY += RESULT_ITEM_HEIGHT

  restoreState()

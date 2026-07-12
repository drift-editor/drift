import std/[os, options, tables]
import uirelays
import uirelays/screen
import uirelays/input
import theme, icons
import ../services/git as gitcmd
import ../utils/text

const
  HeaderHeight = 40
  SectionHeaderHeight = 28
  FileItemHeight = 24
  CommitAreaHeight = 100
  ActionButtonSize = 20

type
  GitRepository = object
    currentBranch: string
    isDirty: bool
    ahead: int
    behind: int

  GitPanelState = enum
    gpsLoading
    gpsReady
    gpsNotRepo

  GitPanel* = ref object
    state: GitPanelState
    currentPath*: string
    repository: Option[GitRepository]
    fileChanges: seq[GitFileChange]
    stagedFiles: seq[string]
    unstagedFiles: seq[string]
    showStaged: bool
    showUnstaged: bool
    selectedFile: string
    scrollOffset: int
    commitMessage: string
    commitInputFocused: bool
    cursorVisible: bool
    lastBlinkTick: int
    hoverRefresh*: bool
    hoverStagedHeader*: bool
    hoverUnstagedHeader*: bool
    hoverCommitBtn*: bool
    hoverCommitInput*: bool
    hoverReviewBtn*: bool
    hoverFilePath*: string
    hoverActionKind*: string
    hoverActionPath*: string
    onReview*: proc()
    onShowDiff*: proc(path: string; staged: bool)
    bounds*: Rect

proc currentBranch*(panel: GitPanel): string =
  if panel.repository.isSome: panel.repository.get().currentBranch else: ""

proc isDirty*(panel: GitPanel): bool =
  if panel.repository.isSome: panel.repository.get().isDirty else: false

proc listBranches*(panel: GitPanel): seq[string] =
  gitcmd.listBranches(panel.currentPath)

proc checkoutBranch*(panel: GitPanel, branch: string): bool =
  gitcmd.checkoutBranch(panel.currentPath, branch)



proc newGitPanel*(): GitPanel =
  GitPanel(
    state: gpsLoading,
    currentPath: "",
    repository: none(GitRepository),
    fileChanges: @[],
    stagedFiles: @[],
    unstagedFiles: @[],
    showStaged: true,
    showUnstaged: true,
    selectedFile: "",
    scrollOffset: 0,
    commitMessage: "",
    commitInputFocused: false,
    cursorVisible: true,
    lastBlinkTick: 0,
    hoverRefresh: false,
    hoverStagedHeader: false,
    hoverUnstagedHeader: false,
    hoverCommitBtn: false,
    hoverFilePath: "",
    hoverActionKind: "",
    hoverActionPath: ""
  )

proc resetHover(panel: GitPanel) =
  panel.hoverRefresh = false
  panel.hoverStagedHeader = false
  panel.hoverUnstagedHeader = false
  panel.hoverCommitBtn = false
  panel.hoverCommitInput = false
  panel.hoverReviewBtn = false
  panel.hoverFilePath = ""
  panel.hoverActionKind = ""
  panel.hoverActionPath = ""

proc updateRepository*(panel: GitPanel) =
  stderr.writeLine("[git] updateRepository currentPath='" & panel.currentPath & "'")
  if panel.currentPath.len == 0:
    stderr.writeLine("[git] currentPath empty, returning")
    return
  if not gitcmd.isGitRepository(panel.currentPath):
    stderr.writeLine("[git] not a git repo")
    panel.state = gpsNotRepo
    return
  panel.state = gpsReady
  panel.currentPath = gitcmd.getRepoRoot(panel.currentPath)
  stderr.writeLine("[git] normalized repo root='" & panel.currentPath & "'")
  let branch = gitcmd.getCurrentBranch(panel.currentPath)
  let (ahead, behind) = gitcmd.getRepoStatus(panel.currentPath)
  panel.fileChanges = gitcmd.parseGitStatus(panel.currentPath)
  let stagedStats = gitcmd.parseGitNumstat(panel.currentPath, cached = true)
  let unstagedStats = gitcmd.parseGitNumstat(panel.currentPath, cached = false)
  for i in 0 ..< panel.fileChanges.len:
    let path = panel.fileChanges[i].path
    if stagedStats.hasKey(path):
      panel.fileChanges[i].stagedAdded = stagedStats[path].added
      panel.fileChanges[i].stagedRemoved = stagedStats[path].removed
    if unstagedStats.hasKey(path):
      panel.fileChanges[i].unstagedAdded = unstagedStats[path].added
      panel.fileChanges[i].unstagedRemoved = unstagedStats[path].removed
  stderr.writeLine("[git] fileChanges.len=" & $panel.fileChanges.len)
  panel.stagedFiles = @[]
  panel.unstagedFiles = @[]
  for change in panel.fileChanges:
    if change.stagedStatus != gfsUnmodified:
      panel.stagedFiles.add(change.path)
    if change.workingStatus != gfsUnmodified:
      panel.unstagedFiles.add(change.path)
  stderr.writeLine("[git] stagedFiles.len=" & $panel.stagedFiles.len & " unstagedFiles.len=" & $panel.unstagedFiles.len)
  panel.repository = some(GitRepository(
    currentBranch: branch,
    isDirty: panel.fileChanges.len > 0,
    ahead: ahead,
    behind: behind
  ))

proc stageFile*(panel: GitPanel, filePath: string): bool =
  if gitcmd.stageFile(panel.currentPath, filePath):
    panel.updateRepository(); true
  else: false

proc unstageFile*(panel: GitPanel, filePath: string): bool =
  if gitcmd.unstageFile(panel.currentPath, filePath):
    panel.updateRepository(); true
  else: false

proc commit*(panel: GitPanel, message: string): bool =
  if gitcmd.commitChanges(panel.currentPath, message):
    panel.commitMessage = ""
    panel.updateRepository(); true
  else: false

proc discardChanges*(panel: GitPanel, filePath: string): bool =
  if gitcmd.discardChanges(panel.currentPath, filePath):
    panel.updateRepository(); true
  else: false

proc addToGitignore*(panel: GitPanel, filePath: string): bool =
  if gitcmd.addToGitignore(panel.currentPath, filePath):
    panel.updateRepository(); true
  else: false


# Return the file path at the given mouse position, or empty string if none.
proc fileAt*(panel: GitPanel, x, y: int, bounds: Rect): tuple[path: string, isStaged: bool] =
  result = ("", false)
  if panel.state != gpsReady:
    return
  let relativeY = y - bounds.y
  if relativeY < HeaderHeight:
    return
  let hasCommitArea = panel.stagedFiles.len > 0
  if hasCommitArea and relativeY >= bounds.h - CommitAreaHeight:
    return
  let scrollRelativeY = relativeY - HeaderHeight + panel.scrollOffset
  if scrollRelativeY < 0:
    return
  var sy = 0
  # Staged section
  if panel.stagedFiles.len > 0:
    if scrollRelativeY >= sy and scrollRelativeY < sy + SectionHeaderHeight:
      return
    sy += SectionHeaderHeight
    if panel.showStaged:
      let fileIdx = (scrollRelativeY - sy) div FileItemHeight
      if fileIdx >= 0 and fileIdx < panel.stagedFiles.len:
        result = (panel.stagedFiles[fileIdx], true)
      sy += panel.stagedFiles.len * FileItemHeight
  # Unstaged section
  if result.path.len == 0 and panel.unstagedFiles.len > 0:
    if scrollRelativeY >= sy and scrollRelativeY < sy + SectionHeaderHeight:
      return
    sy += SectionHeaderHeight
    if panel.showUnstaged:
      let fileIdx = (scrollRelativeY - sy) div FileItemHeight
      var visibleUnstaged: seq[string] = @[]
      for change in panel.fileChanges:
        if change.workingStatus != gfsUnmodified:
          visibleUnstaged.add(change.path)
      if fileIdx >= 0 and fileIdx < visibleUnstaged.len:
        result = (visibleUnstaged[fileIdx], false)

proc handleMouse*(panel: GitPanel, e: Event, bounds: Rect): bool =
  # Mouse wheel scrolling: process first because for MouseWheelEvent
  # e.x/e.y are scroll deltas, not coordinates.
  if e.kind == MouseWheelEvent:
    let hasCommitArea = panel.stagedFiles.len > 0
    let listH = if hasCommitArea: bounds.h - HeaderHeight - CommitAreaHeight else: bounds.h - HeaderHeight
    var contentHeight = 0
    if panel.stagedFiles.len > 0:
      contentHeight += SectionHeaderHeight
      if panel.showStaged:
        contentHeight += panel.stagedFiles.len * FileItemHeight
    if panel.unstagedFiles.len > 0:
      contentHeight += SectionHeaderHeight
      if panel.showUnstaged:
        var unstagedCount = 0
        for change in panel.fileChanges:
          if change.workingStatus != gfsUnmodified:
            inc unstagedCount
        contentHeight += unstagedCount * FileItemHeight
    let maxScroll = max(0, contentHeight - listH)
    let delta = e.y * FileItemHeight
    panel.scrollOffset = clamp(panel.scrollOffset - delta, 0, maxScroll)
    return true

  if not bounds.contains(point(e.x, e.y)):
    if e.kind == MouseMoveEvent:
      panel.resetHover()
    return false

  let relativeY = e.y - bounds.y
  let relativeX = e.x - bounds.x

  # Header
  if relativeY < HeaderHeight:
    let refreshBtnX = bounds.w - 36
    let reviewBtnX = bounds.w - 68
    if e.kind == MouseMoveEvent:
      panel.resetHover()
      panel.hoverRefresh = relativeX >= refreshBtnX and relativeX < refreshBtnX + 28
      panel.hoverReviewBtn = relativeX >= reviewBtnX and relativeX < reviewBtnX + 28
    elif e.kind == MouseDownEvent:
      if relativeX >= reviewBtnX and relativeX < reviewBtnX + 28:
        if panel.onReview != nil:
          panel.onReview()
        return true
      if relativeX >= refreshBtnX and relativeX < refreshBtnX + 28:
        panel.updateRepository()
        return true
    return false

  # Loading / not-repo states have no interactive content below header
  if panel.state != gpsReady:
    if e.kind == MouseMoveEvent:
      panel.resetHover()
    return false

  let hasCommitArea = panel.stagedFiles.len > 0

  # Commit area
  if hasCommitArea and relativeY >= bounds.h - CommitAreaHeight:
    if e.kind == MouseMoveEvent:
      panel.resetHover()
      let commitY = bounds.y + bounds.h - CommitAreaHeight
      let inputBounds = rect(
        bounds.x + 8,
        commitY + 28,
        bounds.w - 16,
        40
      )
      panel.hoverCommitInput = inputBounds.contains(point(e.x, e.y))
      let btnBounds = rect(
        bounds.x + bounds.w - 88,
        commitY + 75,
        80,
        24
      )
      panel.hoverCommitBtn = btnBounds.contains(point(e.x, e.y))
      return true
    elif e.kind == MouseDownEvent:
      let commitY = bounds.y + bounds.h - CommitAreaHeight
      let inputBounds = rect(
        bounds.x + 8,
        commitY + 28,
        bounds.w - 16,
        40
      )
      if inputBounds.contains(point(e.x, e.y)):
        panel.commitInputFocused = true
        panel.cursorVisible = true
        panel.lastBlinkTick = getTicks()
      else:
        panel.commitInputFocused = false
      let btnBounds = rect(
        bounds.x + bounds.w - 88,
        commitY + 75,
        80,
        24
      )
      if btnBounds.contains(point(e.x, e.y)) and panel.commitMessage.len > 0:
        discard panel.commit(panel.commitMessage)
      return true
    return true

  # Empty ready state has no interactive scrollable content
  if panel.stagedFiles.len == 0 and panel.unstagedFiles.len == 0:
    if e.kind == MouseMoveEvent:
      panel.resetHover()
    return false

  # Scrollable file list area
  let scrollRelativeY = relativeY - HeaderHeight + panel.scrollOffset
  if scrollRelativeY < 0:
    if e.kind == MouseMoveEvent:
      panel.resetHover()
    return false

  var y = 0
  var handled = false

  # Staged section
  if panel.stagedFiles.len > 0:
    if scrollRelativeY >= y and scrollRelativeY < y + SectionHeaderHeight:
      if e.kind == MouseMoveEvent:
        panel.resetHover()
        panel.hoverStagedHeader = true
      elif e.kind == MouseDownEvent:
        panel.showStaged = not panel.showStaged
      handled = true
    y += SectionHeaderHeight

    if not handled and panel.showStaged:
      let fileIdx = (scrollRelativeY - y) div FileItemHeight
      if fileIdx >= 0 and fileIdx < panel.stagedFiles.len:
        let file = panel.stagedFiles[fileIdx]
        if e.kind == MouseMoveEvent:
          panel.resetHover()
          panel.hoverFilePath = file
          let unstageX = bounds.w - ActionButtonSize - 8
          if relativeX >= unstageX and relativeX < unstageX + ActionButtonSize:
            panel.hoverActionKind = "unstage"
            panel.hoverActionPath = file
        elif e.kind == MouseDownEvent:
          let unstageX = bounds.w - ActionButtonSize - 8
          if relativeX >= unstageX and relativeX < unstageX + ActionButtonSize:
            panel.selectedFile = file
            discard panel.unstageFile(file)
          else:
            panel.selectedFile = file
            if panel.onShowDiff != nil:
              panel.onShowDiff(file, true)
        handled = true
      y += panel.stagedFiles.len * FileItemHeight

  # Unstaged section
  if not handled and panel.unstagedFiles.len > 0:
    if scrollRelativeY >= y and scrollRelativeY < y + SectionHeaderHeight:
      if e.kind == MouseMoveEvent:
        panel.resetHover()
        panel.hoverUnstagedHeader = true
      elif e.kind == MouseDownEvent:
        panel.showUnstaged = not panel.showUnstaged
      handled = true
    y += SectionHeaderHeight

    if not handled and panel.showUnstaged:
      let fileIdx = (scrollRelativeY - y) div FileItemHeight
      var visibleUnstaged: seq[GitFileChange] = @[]
      for change in panel.fileChanges:
        if change.workingStatus != gfsUnmodified:
          visibleUnstaged.add(change)
      if fileIdx >= 0 and fileIdx < visibleUnstaged.len:
        let change = visibleUnstaged[fileIdx]
        if e.kind == MouseMoveEvent:
          panel.resetHover()
          panel.hoverFilePath = change.path
          let stageX = bounds.w - ActionButtonSize * 2 - 12
          let discardX = stageX + ActionButtonSize + 4
          if relativeX >= stageX and relativeX < stageX + ActionButtonSize:
            panel.hoverActionKind = "stage"
            panel.hoverActionPath = change.path
          elif relativeX >= discardX and relativeX < discardX + ActionButtonSize:
            panel.hoverActionKind = "discard"
            panel.hoverActionPath = change.path
        elif e.kind == MouseDownEvent:
          let stageX = bounds.w - ActionButtonSize * 2 - 12
          let discardX = stageX + ActionButtonSize + 4
          if relativeX >= stageX and relativeX < stageX + ActionButtonSize:
            panel.selectedFile = change.path
            discard panel.stageFile(change.path)
          elif relativeX >= discardX and relativeX < discardX + ActionButtonSize:
            panel.selectedFile = change.path
            discard panel.discardChanges(change.path)
          else:
            panel.selectedFile = change.path
            if panel.onShowDiff != nil:
              panel.onShowDiff(change.path, false)
        handled = true

  if not handled and e.kind == MouseMoveEvent:
    panel.resetHover()

  if handled:
    return true

  false

proc handleInput*(panel: GitPanel, e: Event): bool =
  if e.kind != KeyDownEvent:
    return false

  case e.key
  of KeyEnter:
    if panel.commitInputFocused and panel.commitMessage.len > 0:
      discard panel.commit(panel.commitMessage)
      return true
  of KeyEsc:
    panel.commitInputFocused = false
    return true
  of KeyBackspace:
    if panel.commitInputFocused and panel.commitMessage.len > 0:
      panel.commitMessage.setLen(panel.commitMessage.len - 1)
      panel.cursorVisible = true
      panel.lastBlinkTick = getTicks()
      return true
  else:
    discard
  false

proc handleTextInput*(panel: GitPanel, e: Event): bool =
  if not panel.commitInputFocused:
    return false
  if e.kind != TextInputEvent:
    return false
  var text = ""
  for c in e.text:
    if c == '\0': break
    text.add(c)
  if text.len == 0 or text == "\b" or text == "\x7F":
    return false
  panel.commitMessage.add(text)
  panel.cursorVisible = true
  panel.lastBlinkTick = getTicks()
  return true

# Rendering Helpers

proc getStatusLabel(status: GitFileStatus): string =
  case status
  of gfsModified: "M"
  of gfsAdded: "A"
  of gfsDeleted: "D"
  of gfsRenamed: "R"
  of gfsUntracked: "?"
  of gfsConflict: "C"
  else: ""

proc getStatusColor(status: GitFileStatus): Color =
  case status
  of gfsModified: currentTheme.getColor(tcWarning)
  of gfsAdded, gfsUntracked: currentTheme.getColor(tcSuccess)
  of gfsDeleted, gfsConflict: currentTheme.getColor(tcError)
  of gfsRenamed: currentTheme.getColor(tcAccent)
  else: currentTheme.getColor(tcTextSecondary)

proc measureDiffStats(font: Font, added, removed: int): int =
  var w = 0
  if added > 0:
    w += measureText(font, "+" & $added).w + 4
  if removed > 0:
    w += measureText(font, "-" & $removed).w
  w

proc drawDiffStats(font: Font, x, y: int, added, removed: int) =
  var cx = x
  if added > 0:
    let text = "+" & $added
    discard drawText(font, cx, y, text, currentTheme.getColor(tcSuccess), color(0, 0, 0, 0))
    cx += measureText(font, text).w + 4
  if removed > 0:
    let text = "-" & $removed
    discard drawText(font, cx, y, text, currentTheme.getColor(tcError), color(0, 0, 0, 0))

proc drawFilePath(font: Font, x, y: int, filePath: string, maxWidth: int, textC, textMuted: Color) =
  let fileName = extractFilename(filePath)
  let dirName = parentDir(filePath)
  let nameW = measureText(font, fileName).w
  let spacing = 6

  if dirName.len > 0 and dirName != ".":
    let availableForDir = maxWidth - nameW - spacing
    if availableForDir > 20:
      let dirText = truncateText(dirName, font, availableForDir)
      discard drawText(font, x, y, fileName, textC, color(0, 0, 0, 0))
      discard drawText(font, x + nameW + spacing, y, dirText, textMuted, color(0, 0, 0, 0))
    else:
      let displayName = truncateText(fileName, font, maxWidth)
      discard drawText(font, x, y, displayName, textC, color(0, 0, 0, 0))
  else:
    let displayName = truncateText(fileName, font, maxWidth)
    discard drawText(font, x, y, displayName, textC, color(0, 0, 0, 0))

proc renderCenteredMessage(bounds: Rect, font: Font, msg: string, icon: IconId, color: Color) =
  let iconW = if icon != iiNone: 20 else: 0
  let textW = measureText(font, msg).w
  let totalW = iconW + textW + (if icon != iiNone: 8 else: 0)
  let cx = bounds.x + (bounds.w - totalW) div 2
  let cy = bounds.y + HeaderHeight + (bounds.h - HeaderHeight) div 2 - 8
  var x = cx
  if icon != iiNone:
    drawIcon(icon, x, cy)
    x += iconW + 8
  discard drawText(font, x, cy, msg, color, color(0, 0, 0, 0))

# Rendering

proc render*(panel: GitPanel, bounds: Rect, font: Font) =
  panel.bounds = bounds

  let bg = currentTheme.getColor(tcSurface)
  let bgHover = currentTheme.getColor(tcSurfaceHover)
  let borderC = currentTheme.getColor(tcBorder)
  let textC = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let accentC = currentTheme.getColor(tcAccent)
  let accentHover = currentTheme.getColor(tcAccentHover)
  let selectionC = currentTheme.getColor(tcSelection)
  let headerBg = currentTheme.getColor(tcBackground)

  # Background
  fillRect(bounds, bg)
  # Right edge border
  fillRect(rect(bounds.x + bounds.w - 1, bounds.y, 1, bounds.h), borderC)

  # Header (blends with panel surface, no separate background)
  let headerBounds = rect(bounds.x, bounds.y, bounds.w, HeaderHeight)
  fillRect(headerBounds, bg)

  var branchText = "Not a git repository"
  if panel.repository.isSome:
    let repo = panel.repository.get()
    branchText = repo.currentBranch
    if repo.ahead > 0 or repo.behind > 0:
      branchText &= " ↑" & $repo.ahead & " ↓" & $repo.behind
    if repo.isDirty:
      branchText &= " •"

  drawIcon(iiGitBranch, bounds.x + 8, bounds.y + 10)
  discard drawText(font, bounds.x + 28, bounds.y + 10, branchText, textC, color(0, 0, 0, 0))

  # AI Review button
  let reviewBtnX = bounds.x + bounds.w - 68
  let reviewBtnBounds = rect(reviewBtnX, bounds.y + 6, 28, 28)
  if panel.hoverReviewBtn:
    fillRect(reviewBtnBounds, bgHover)
  drawIconCentered(iiSparkle, reviewBtnBounds)

  # Refresh button
  let refreshBtnX = bounds.x + bounds.w - 36
  let refreshBtnBounds = rect(refreshBtnX, bounds.y + 6, 28, 28)
  if panel.hoverRefresh:
    fillRect(refreshBtnBounds, bgHover)
  drawIconCentered(iiRefresh, refreshBtnBounds)

  # Loading / Not-repo states
  if panel.state == gpsLoading:
    renderCenteredMessage(bounds, font, "Loading…", iiGitBranch, textMuted)
    return
  elif panel.state == gpsNotRepo:
    renderCenteredMessage(bounds, font, "No Git repository", iiGitBranch, textMuted)
    return

  # Ready state
  let hasCommitArea = panel.stagedFiles.len > 0
  let listY = bounds.y + HeaderHeight
  let listH = if hasCommitArea: bounds.h - HeaderHeight - CommitAreaHeight else: bounds.h - HeaderHeight

  # Empty ready state
  if panel.stagedFiles.len == 0 and panel.unstagedFiles.len == 0:
    renderCenteredMessage(bounds, font, "No changes", iiCheck, textMuted)
    return

  # Compute content height and clamp scroll
  var contentHeight = 0
  if panel.stagedFiles.len > 0:
    contentHeight += SectionHeaderHeight
    if panel.showStaged:
      contentHeight += panel.stagedFiles.len * FileItemHeight
  if panel.unstagedFiles.len > 0:
    contentHeight += SectionHeaderHeight
    if panel.showUnstaged:
      var unstagedCount = 0
      for change in panel.fileChanges:
        if change.workingStatus != gfsUnmodified:
          inc unstagedCount
      contentHeight += unstagedCount * FileItemHeight
  let maxScroll = max(0, contentHeight - listH)
  panel.scrollOffset = min(panel.scrollOffset, maxScroll)

  # Render scrollable content with clipping
  saveState()
  setClipRect(rect(bounds.x, listY, bounds.w, listH))

  var y = listY - panel.scrollOffset

  # Staged section
  if panel.stagedFiles.len > 0:
    let sectionBounds = rect(bounds.x, y, bounds.w, SectionHeaderHeight)
    fillRect(sectionBounds, if panel.hoverStagedHeader: bgHover else: bg)
    let arrowIcon = if panel.showStaged: iiChevronDown else: iiChevronRight
    drawIcon(arrowIcon, bounds.x + 8, y + 6)
    let stagedText = "Staged Changes (" & $panel.stagedFiles.len & ")"
    discard drawText(font, bounds.x + 28, y + 5, stagedText, textC, color(0, 0, 0, 0))
    var stagedAddedTotal = 0
    var stagedRemovedTotal = 0
    for file in panel.stagedFiles:
      for change in panel.fileChanges:
        if change.path == file:
          stagedAddedTotal += change.stagedAdded
          stagedRemovedTotal += change.stagedRemoved
          break
    let stagedStatsW = measureDiffStats(font, stagedAddedTotal, stagedRemovedTotal)
    if stagedStatsW > 0:
      let stagedStatsX = bounds.x + bounds.w - stagedStatsW - 10
      drawDiffStats(font, stagedStatsX, y + 5, stagedAddedTotal, stagedRemovedTotal)
    y += SectionHeaderHeight

    if panel.showStaged:
      for file in panel.stagedFiles:
        let itemBounds = rect(bounds.x, y, bounds.w, FileItemHeight)
        if file == panel.selectedFile:
          fillRect(itemBounds, selectionC)
        elif panel.hoverFilePath == file:
          fillRect(itemBounds, bgHover)

        var status = gfsUnmodified
        var added = 0
        var removed = 0
        for change in panel.fileChanges:
          if change.path == file:
            status = change.stagedStatus
            added = change.stagedAdded
            removed = change.stagedRemoved
            break

        let isHovered = panel.hoverFilePath == file
        let statsW = measureDiffStats(font, added, removed)
        let rightMargin = if isHovered: 34 else: 30
        let fileMaxW = bounds.w - 56 - statsW
        drawFilePath(font, bounds.x + 12, y + 4, file, fileMaxW, textC, textMuted)

        if statsW > 0:
          let statsX = bounds.x + bounds.w - statsW - rightMargin
          drawDiffStats(font, statsX, y + 4, added, removed)

        if isHovered:
          let unstageX = bounds.x + bounds.w - ActionButtonSize - 8
          let unstageBounds = rect(unstageX, y + 2, ActionButtonSize, ActionButtonSize)
          let isHoverUnstage = panel.hoverActionKind == "unstage" and panel.hoverActionPath == file
          if isHoverUnstage:
            fillRect(unstageBounds, bgHover)
          drawIconCentered(iiRemove, unstageBounds)
        else:
          let label = getStatusLabel(status)
          let labelW = measureText(font, label).w
          let labelColor = getStatusColor(status)
          discard drawText(font, bounds.x + bounds.w - labelW - 10, y + 4, label, labelColor, color(0, 0, 0, 0))

        y += FileItemHeight

  # Unstaged section
  if panel.unstagedFiles.len > 0:
    let sectionBounds = rect(bounds.x, y, bounds.w, SectionHeaderHeight)
    fillRect(sectionBounds, if panel.hoverUnstagedHeader: bgHover else: bg)
    let arrowIcon = if panel.showUnstaged: iiChevronDown else: iiChevronRight
    drawIcon(arrowIcon, bounds.x + 8, y + 6)
    let unstagedText = "Changes (" & $panel.unstagedFiles.len & ")"
    discard drawText(font, bounds.x + 28, y + 5, unstagedText, textC, color(0, 0, 0, 0))
    var unstagedAddedTotal = 0
    var unstagedRemovedTotal = 0
    for change in panel.fileChanges:
      if change.workingStatus != gfsUnmodified:
        unstagedAddedTotal += change.unstagedAdded
        unstagedRemovedTotal += change.unstagedRemoved
    let unstagedStatsW = measureDiffStats(font, unstagedAddedTotal, unstagedRemovedTotal)
    if unstagedStatsW > 0:
      let unstagedStatsX = bounds.x + bounds.w - unstagedStatsW - 10
      drawDiffStats(font, unstagedStatsX, y + 5, unstagedAddedTotal, unstagedRemovedTotal)
    y += SectionHeaderHeight

    if panel.showUnstaged:
      for change in panel.fileChanges:
        if change.workingStatus == gfsUnmodified:
          continue
        let itemBounds = rect(bounds.x, y, bounds.w, FileItemHeight)
        if change.path == panel.selectedFile:
          fillRect(itemBounds, selectionC)
        elif panel.hoverFilePath == change.path:
          fillRect(itemBounds, bgHover)

        let isHovered = panel.hoverFilePath == change.path
        let added = change.unstagedAdded
        let removed = change.unstagedRemoved
        let statsW = measureDiffStats(font, added, removed)
        let rightMargin = if isHovered: 54 else: 50
        let fileMaxW = bounds.w - 76 - statsW
        drawFilePath(font, bounds.x + 12, y + 4, change.path, fileMaxW, textC, textMuted)

        if statsW > 0:
          let statsX = bounds.x + bounds.w - statsW - rightMargin
          drawDiffStats(font, statsX, y + 4, added, removed)

        if isHovered:
          let stageX = bounds.x + bounds.w - ActionButtonSize * 2 - 12
          let stageBounds = rect(stageX, y + 2, ActionButtonSize, ActionButtonSize)
          let isHoverStage = panel.hoverActionKind == "stage" and panel.hoverActionPath == change.path
          if isHoverStage:
            fillRect(stageBounds, bgHover)
          drawIconCentered(iiAdd, stageBounds)

          let discardX = bounds.x + bounds.w - ActionButtonSize - 8
          let discardBounds = rect(discardX, y + 2, ActionButtonSize, ActionButtonSize)
          let isHoverDiscard = panel.hoverActionKind == "discard" and panel.hoverActionPath == change.path
          if isHoverDiscard:
            fillRect(discardBounds, bgHover)
          drawIconCentered(iiDiscard, discardBounds)
        else:
          let label = getStatusLabel(change.workingStatus)
          let labelW = measureText(font, label).w
          let labelColor = getStatusColor(change.workingStatus)
          discard drawText(font, bounds.x + bounds.w - labelW - 10, y + 4, label, labelColor, color(0, 0, 0, 0))

        y += FileItemHeight

  restoreState()

  # Commit message area (only if there are staged files)
  if hasCommitArea:
    let commitY = bounds.y + bounds.h - CommitAreaHeight
    let commitBounds = rect(bounds.x, commitY, bounds.w, CommitAreaHeight)
    fillRect(commitBounds, headerBg)
    fillRect(rect(bounds.x, commitY, bounds.w, 1), borderC)

    # Message label
    discard drawText(font, bounds.x + 8, commitY + 8, "Message:", textMuted, color(0, 0, 0, 0))

    # Message input
    let inputBounds = rect(
      bounds.x + 8,
      commitY + 28,
      bounds.w - 16,
      40
    )
    fillRect(inputBounds, bg)
    let inputBorderColor = if panel.commitInputFocused: accentC else: borderC
    fillRect(rect(inputBounds.x, inputBounds.y, inputBounds.w, 1), inputBorderColor)
    fillRect(rect(inputBounds.x, inputBounds.y + inputBounds.h - 1, inputBounds.w, 1), inputBorderColor)
    fillRect(rect(inputBounds.x, inputBounds.y, 1, inputBounds.h), inputBorderColor)
    fillRect(rect(inputBounds.x + inputBounds.w - 1, inputBounds.y, 1, inputBounds.h), inputBorderColor)

    # Message text
    let msg = if panel.commitMessage.len > 0: panel.commitMessage else: "Message (Ctrl+Enter to commit)"
    let msgColor = if panel.commitMessage.len > 0: textC else: textMuted
    discard drawText(font, inputBounds.x + 8, inputBounds.y + 10, msg, msgColor, color(0, 0, 0, 0))

    # Cursor blink
    var blink = false
    if panel.commitInputFocused:
      let ticks = getTicks()
      if ticks - panel.lastBlinkTick > 500:
        panel.cursorVisible = not panel.cursorVisible
        panel.lastBlinkTick = ticks
      blink = panel.cursorVisible

    if panel.commitInputFocused and blink:
      let cursorX = inputBounds.x + 8 + measureText(font, panel.commitMessage).w
      let cursorH = 20
      fillRect(rect(cursorX, inputBounds.y + (inputBounds.h - cursorH) div 2, 2, cursorH), textC)

    # Commit button with icon
    let btnBounds = rect(
      bounds.x + bounds.w - 88,
      commitY + 75,
      80,
      24
    )
    let btnEnabled = panel.commitMessage.len > 0
    let btnColor = if btnEnabled:
      (if panel.hoverCommitBtn: accentHover else: accentC)
    else:
      currentTheme.getColor(tcSurface)
    fillRect(btnBounds, btnColor)
    fillRect(rect(btnBounds.x, btnBounds.y, btnBounds.w, 1), borderC)
    fillRect(rect(btnBounds.x, btnBounds.y + btnBounds.h - 1, btnBounds.w, 1), borderC)
    fillRect(rect(btnBounds.x, btnBounds.y, 1, btnBounds.h), borderC)
    fillRect(rect(btnBounds.x + btnBounds.w - 1, btnBounds.y, 1, btnBounds.h), borderC)

    let iconX = btnBounds.x + 8
    let textX = btnBounds.x + 28
    let btnTextColor = if btnEnabled: textC else: textMuted
    drawIcon(iiGitCommit, iconX, btnBounds.y + 4)
    discard drawText(font, textX, btnBounds.y + 4, "Commit", btnTextColor, color(0, 0, 0, 0))

proc toggle*(panel: GitPanel) =
  if panel.currentPath.len > 0:
    panel.updateRepository()

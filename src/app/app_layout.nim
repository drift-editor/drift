## Layout computation for the main app frame

import uirelays/screen
import uirelays/coords
import ../ui/theme

const
  SidebarWidth* = 200
  TopBarHeight* = 32
  StatusHeight* = 26
  TerminalHeaderHeight* = 24
  TerminalMinHeight* = 100
  TerminalMaxHeight* = 600
  RightPanelWidth* = 280
  TitleBarButtonCount* = 4
  TitleBarButtonWidth* = 40
  TabBarStartX* = 200

type
  AppLayout* = object
    topBar*: Rect
    sidebar*: Rect
    editor*: Rect
    term*: Rect
    termHeader*: Rect
    bottomPanelTabs*: Rect
    rightPanel*: Rect
    status*: Rect
    screen*: Rect

proc computeLayout*(width, height: int; sidebarVisible, showTerminal: bool; terminalHeight: int; sidebarWidth: int = SidebarWidth; rightPanelVisible: bool = false; rightPanelWidth: int = RightPanelWidth): AppLayout =
  let termH = if showTerminal: terminalHeight else: 0
  let bodyH = max(0, height - TopBarHeight - StatusHeight - termH)
  let sidebarW = if sidebarVisible: sidebarWidth else: 0
  let rightW = if rightPanelVisible: rightPanelWidth else: 0

  result.screen = rect(0, 0, width, height)
  result.topBar = rect(0, 0, width, TopBarHeight)
  result.sidebar = rect(0, TopBarHeight, sidebarW, bodyH)
  result.editor = rect(sidebarW, TopBarHeight, max(0, width - sidebarW - rightW), bodyH)
  result.rightPanel = rect(width - rightW, TopBarHeight, rightW, bodyH)
  result.term = rect(0, height - StatusHeight - termH, width, max(0, termH))
  result.termHeader = rect(result.term.x, result.term.y, result.term.w, TerminalHeaderHeight)
  result.bottomPanelTabs = result.termHeader
  result.status = rect(0, height - StatusHeight, width, StatusHeight)

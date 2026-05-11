## Tab Bar Component for uirelays
## Immediate-mode tab bar with fillRect + drawText

import std/options
import uirelays
import uirelays/[coords, screen]
import theme

const
  TabHeight = 32
  TabMinWidth = 120
  TabMaxWidth = 200
  TabPadding = 12
  CloseButtonSize = 16

type
  Tab* = ref object
    id*: string
    title*: string
    isModified*: bool
    isActive*: bool
    bounds*: Rect

  TabBar* = ref object
    tabs*: seq[Tab]
    activeTabId*: string
    bounds*: Rect
    scrollOffset*: int
    onTabChange*: proc(tabId: string)
    onTabClose*: proc(tabId: string)
    tabsDirty*: bool
    hoverCloseTabIndex*: int

# Creation

proc newTab*(id, title: string): Tab =
  Tab(
    id: id,
    title: title,
    isModified: false,
    isActive: false,
    bounds: rect(0, 0, TabMinWidth, TabHeight)
  )

proc newTabBar*(): TabBar =
  TabBar(
    tabs: @[],
    activeTabId: "",
    bounds: rect(0, 0, 800, TabHeight),
    hoverCloseTabIndex: -1,
    scrollOffset: 0,
    onTabChange: nil,
    onTabClose: nil,
    tabsDirty: true
  )

# Management

proc addTab*(bar: TabBar, tab: Tab) =
  bar.tabs.add(tab)
  bar.tabsDirty = true
  if bar.activeTabId.len == 0:
    bar.activeTabId = tab.id
    tab.isActive = true

proc addTab*(bar: TabBar, id, title: string): Tab =
  let tab = newTab(id, title)
  bar.addTab(tab)
  tab

proc removeTab*(bar: TabBar, tabId: string): bool =
  for i, tab in bar.tabs:
    if tab.id == tabId:
      bar.tabs.delete(i)
      bar.tabsDirty = true
      if bar.activeTabId == tabId:
        if bar.tabs.len > 0:
          let newIndex = min(i, bar.tabs.len - 1)
          bar.activeTabId = bar.tabs[newIndex].id
          bar.tabs[newIndex].isActive = true
          if bar.onTabChange != nil:
            bar.onTabChange(bar.activeTabId)
        else:
          bar.activeTabId = ""
      return true
  false

proc getTab*(bar: TabBar, tabId: string): Option[Tab] =
  for tab in bar.tabs:
    if tab.id == tabId:
      return some(tab)
  none(Tab)

proc getActiveTab*(bar: TabBar): Option[Tab] =
  bar.getTab(bar.activeTabId)

proc setActiveTab*(bar: TabBar, tabId: string): bool =
  let changed = bar.activeTabId != tabId
  var found = false
  for tab in bar.tabs:
    tab.isActive = (tab.id == tabId)
    if tab.id == tabId:
      bar.activeTabId = tabId
      found = true
  if found and changed and bar.onTabChange != nil:
    bar.onTabChange(tabId)
  found

proc clearTabs*(bar: TabBar) =
  bar.tabs.setLen(0)
  bar.activeTabId = ""
  bar.tabsDirty = true

proc updateTabTitle*(bar: TabBar, tabId, title: string) =
  for tab in bar.tabs:
    if tab.id == tabId:
      if tab.title != title:
        tab.title = title
        bar.tabsDirty = true
      break

proc updateTabModified*(bar: TabBar, tabId: string, modified: bool) =
  for tab in bar.tabs:
    if tab.id == tabId:
      if tab.isModified != modified:
        tab.isModified = modified
        bar.tabsDirty = true
      break

proc updateLayout*(bar: TabBar, font: Font) =
  var x = bar.bounds.x + bar.scrollOffset
  for tab in bar.tabs:
    let textWidth = measureText(font, tab.title).w + TabPadding * 2 + CloseButtonSize
    let width = clamp(textWidth, TabMinWidth, TabMaxWidth)
    tab.bounds = rect(x, bar.bounds.y, width, TabHeight)
    x += width

proc setBounds*(bar: TabBar, bounds: Rect) =
  bar.bounds = bounds
  bar.tabsDirty = true

# Input

proc handleMouse*(bar: TabBar, pos: Point, pressed: bool): bool =
  if not bar.bounds.contains(pos):
    return false
  for tab in bar.tabs:
    if tab.bounds.contains(pos):
      let closeBounds = rect(
        tab.bounds.x + tab.bounds.w - CloseButtonSize - 6,
        tab.bounds.y + (TabHeight - CloseButtonSize) div 2,
        CloseButtonSize,
        CloseButtonSize
      )
      if pressed and closeBounds.contains(pos):
        if bar.onTabClose != nil:
          bar.onTabClose(tab.id)
        else:
          discard bar.removeTab(tab.id)
        return true
      if pressed:
        discard bar.setActiveTab(tab.id)
      return true
  true

proc handleHover*(bar: TabBar, pos: Point) =
  bar.hoverCloseTabIndex = -1
  if not bar.bounds.contains(pos):
    return
  for i, tab in bar.tabs:
    if tab.bounds.contains(pos):
      let closeBounds = rect(
        tab.bounds.x + tab.bounds.w - CloseButtonSize - 6,
        tab.bounds.y + (TabHeight - CloseButtonSize) div 2,
        CloseButtonSize,
        CloseButtonSize
      )
      if closeBounds.contains(pos):
        bar.hoverCloseTabIndex = i
      return

# Rendering

proc render*(bar: TabBar, font: Font, bounds: Rect) =
  if bar.tabs.len == 0:
    return
  bar.bounds = bounds
  if bar.tabsDirty:
    bar.updateLayout(font)
    bar.tabsDirty = false

  let bgColor = currentTheme.getColor(tcBackground)
  let surfaceColor = currentTheme.getColor(tcSurface)
  let borderColor = currentTheme.getColor(tcBorder)
  let accentColor = currentTheme.getColor(tcAccent)
  let textColor = currentTheme.getColor(tcText)
  let warningColor = currentTheme.getColor(tcWarning)

  fillRect(bar.bounds, bgColor)
  fillRect(rect(bar.bounds.x, bar.bounds.y + TabHeight - 1, bar.bounds.w, 1), borderColor)

  for i, tab in bar.tabs:
    if tab.bounds.x + tab.bounds.w < bar.bounds.x or tab.bounds.x > bar.bounds.x + bar.bounds.w:
      continue

    let tabBg = if tab.isActive: bgColor else: surfaceColor
    fillRect(tab.bounds, tabBg)

    if tab.isActive:
      fillRect(rect(tab.bounds.x, tab.bounds.y, tab.bounds.w, 2), accentColor)

    if not tab.isActive:
      fillRect(rect(tab.bounds.x + tab.bounds.w - 1, tab.bounds.y + 4, 1, TabHeight - 8), borderColor)

    var titleX = tab.bounds.x + TabPadding
    if tab.isModified:
      fillRect(rect(titleX, tab.bounds.y + TabHeight div 2 - 3, 6, 6), warningColor)
      titleX += 10

    let maxTextWidth = tab.bounds.w - TabPadding * 2 - CloseButtonSize - (if tab.isModified: 10 else: 0)
    var displayTitle = tab.title
    let ellipsis = "..."
    while displayTitle.len > 0 and measureText(font, displayTitle & ellipsis).w > maxTextWidth:
      displayTitle = displayTitle[0..^2]
    if displayTitle.len < tab.title.len:
      displayTitle = displayTitle & ellipsis

    let textY = tab.bounds.y + (TabHeight - currentTheme.fontSize) div 2
    discard drawText(font, titleX, textY, displayTitle, textColor, color(0, 0, 0, 0))

    let closeBounds = rect(
      tab.bounds.x + tab.bounds.w - CloseButtonSize - 6,
      tab.bounds.y + (TabHeight - CloseButtonSize) div 2,
      CloseButtonSize,
      CloseButtonSize
    )
    let closeBg = if bar.hoverCloseTabIndex == i:
      currentTheme.getColor(tcSurfaceHover)
    else:
      currentTheme.getColor(tcBackground)
    fillRect(closeBounds, closeBg)
    let closeText = "×"
    let closeExt = measureText(font, closeText)
    let closeTextX = closeBounds.x + (closeBounds.w - closeExt.w) div 2
    let closeTextY = closeBounds.y + (closeBounds.h - closeExt.h) div 2
    let closeFg = if bar.hoverCloseTabIndex == i:
      currentTheme.getColor(tcText)
    else:
      currentTheme.getColor(tcTextSecondary)
    discard drawText(font, closeTextX, closeTextY, closeText, closeFg, color(0, 0, 0, 0))

# INTEGRATION_NOTES
# To wire this into src/app/app.nim without modifying that file, create the
# TabBar in a wrapper module or main entry, then:
#
#   var bar = newTabBar()
#   bar.addTab("1", "untitled")
#   bar.onTabChange = proc(id: string) =
#     for i, b in app.buffers:
#       if $(i) == id: app.switchBuffer(i)
#   bar.onTabClose = proc(id: string) =
#     discard bar.removeTab(id)
#     # also close buffer in app if desired
#
# In the frame loop, sync tab titles from app.buffers, then render:
#   bar.updateTabTitle(id, title)
#   bar.updateTabModified(id, modified)
#   bar.render(app.font, app.cells["title"])
#
# Pass mouse events:
#   of MouseDownEvent:
#     if bar.handleMouse(point(e.x, e.y), true):
#       e = default Event

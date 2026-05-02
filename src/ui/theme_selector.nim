## Theme Selector - dedicated overlay for choosing color themes
## with live preview (no save until confirmed).

import std/strutils
import uirelays
import uirelays/[coords, screen, input]
import theme, icons, theme_loader

const
  SelectorWidth = 400
  SelectorHeight = 380
  ItemHeight = 36
  HeaderHeight = 48
  MaxVisibleItems = 9

type
  ThemeSelector* = ref object
    themes*: seq[string]
    selectedIndex*: int
    hoverIndex*: int
    isVisible*: bool
    bounds*: Rect
    originalTheme*: string
    onApply*: proc(name: string)
    onPreview*: proc(name: string)
    onCancel*: proc()

proc newThemeSelector*(): ThemeSelector =
  ThemeSelector(
    themes: @[],
    selectedIndex: 0,
    hoverIndex: -1,
    isVisible: false,
    bounds: rect(0, 0, SelectorWidth, SelectorHeight),
    originalTheme: ""
  )

proc refreshThemes*(selector: ThemeSelector) =
  selector.themes = listAvailableThemes()
  if selector.selectedIndex >= selector.themes.len:
    selector.selectedIndex = max(0, selector.themes.len - 1)

proc updateLayout*(selector: ThemeSelector, viewport: Rect) =
  let x = (viewport.w - SelectorWidth) div 2 + viewport.x
  let y = (viewport.h - SelectorHeight) div 3 + viewport.y
  selector.bounds = rect(x, y, SelectorWidth, SelectorHeight)

proc show*(selector: ThemeSelector, currentThemeName: string = "") =
  selector.refreshThemes()
  selector.originalTheme = currentThemeName
  selector.selectedIndex = 0
  selector.hoverIndex = -1
  # Find current theme index
  for i, t in selector.themes:
    if t == selector.originalTheme:
      selector.selectedIndex = i
      break
  selector.isVisible = true

proc hide*(selector: ThemeSelector) =
  selector.isVisible = false
  selector.hoverIndex = -1

proc toggle*(selector: ThemeSelector) =
  if selector.isVisible:
    selector.hide()
  else:
    selector.show()

proc applyCurrent*(selector: ThemeSelector) =
  if selector.selectedIndex >= 0 and selector.selectedIndex < selector.themes.len:
    let name = selector.themes[selector.selectedIndex]
    if selector.onApply != nil:
      selector.onApply(name)
  selector.hide()

proc previewCurrent*(selector: ThemeSelector) =
  if selector.selectedIndex >= 0 and selector.selectedIndex < selector.themes.len:
    let name = selector.themes[selector.selectedIndex]
    if selector.onPreview != nil:
      selector.onPreview(name)

proc cancel*(selector: ThemeSelector) =
  if selector.onCancel != nil:
    selector.onCancel()
  selector.hide()

proc handleInput*(selector: ThemeSelector, e: Event): bool =
  if not selector.isVisible:
    return false
  case e.kind
  of KeyDownEvent:
    case e.key
    of KeyEsc:
      selector.cancel()
      return true
    of KeyEnter:
      selector.applyCurrent()
      return true
    of KeyUp:
      if selector.selectedIndex > 0:
        selector.selectedIndex -= 1
        selector.previewCurrent()
      return true
    of KeyDown:
      let maxIdx = selector.themes.len - 1
      if selector.selectedIndex < maxIdx:
        selector.selectedIndex += 1
        selector.previewCurrent()
      return true
    else:
      return false
  of MouseDownEvent:
    let mousePos = point(e.x, e.y)
    if not selector.bounds.contains(mousePos):
      selector.cancel()
      return true
    let listY = selector.bounds.y + HeaderHeight
    let listH = min(MaxVisibleItems, selector.themes.len) * ItemHeight
    let listBounds = rect(selector.bounds.x, listY, selector.bounds.w, listH)
    if listBounds.contains(mousePos):
      let relativeY = mousePos.y - listY
      let index = relativeY div ItemHeight
      if index >= 0 and index < selector.themes.len:
        selector.selectedIndex = index
        selector.previewCurrent()
        selector.applyCurrent()
      return true
    return true
  of MouseMoveEvent:
    let mousePos = point(e.x, e.y)
    if not selector.bounds.contains(mousePos):
      selector.hoverIndex = -1
      return false
    let listY = selector.bounds.y + HeaderHeight
    let listH = min(MaxVisibleItems, selector.themes.len) * ItemHeight
    let listBounds = rect(selector.bounds.x, listY, selector.bounds.w, listH)
    if listBounds.contains(mousePos):
      let relativeY = mousePos.y - listY
      let index = relativeY div ItemHeight
      if index >= 0 and index < selector.themes.len:
        selector.hoverIndex = index
      else:
        selector.hoverIndex = -1
    else:
      selector.hoverIndex = -1
    return true
  else:
    discard
  false

proc render*(selector: ThemeSelector, font: Font, viewport: Rect) =
  if not selector.isVisible:
    return
  selector.updateLayout(viewport)

  let bg = currentTheme.getColor(tcBackground)
  let surface = currentTheme.getColor(tcSurface)
  let border = currentTheme.getColor(tcBorder)
  let text = currentTheme.getColor(tcText)
  let textSecondary = currentTheme.getColor(tcTextSecondary)
  let accent = currentTheme.getColor(tcAccent)
  let selection = currentTheme.getColor(tcSelection)
  let surfaceHover = currentTheme.getColor(tcSurfaceHover)

  # Backdrop
  fillRect(rect(0, 0, viewport.w, viewport.h), color(0, 0, 0, 128))

  # Panel background
  fillRect(selector.bounds, surface)
  fillRect(rect(selector.bounds.x, selector.bounds.y + selector.bounds.h - 1, selector.bounds.w, 1), border)

  # Header
  let headerBounds = rect(selector.bounds.x, selector.bounds.y, selector.bounds.w, HeaderHeight)
  fillRect(headerBounds, bg)
  fillRect(rect(headerBounds.x, headerBounds.y + headerBounds.h - 1, headerBounds.w, 1), border)
  discard drawText(font, headerBounds.x + 16, headerBounds.y + 14, "Select Theme", text, color(0, 0, 0, 0))

  # Theme list
  let listY = selector.bounds.y + HeaderHeight
  let maxItems = min(MaxVisibleItems, selector.themes.len)
  for i in 0..<maxItems:
    let themeName = selector.themes[i]
    let itemY = listY + i * ItemHeight
    let itemBounds = rect(selector.bounds.x + 1, itemY, selector.bounds.w - 2, ItemHeight)

    # Selection / hover background
    if i == selector.selectedIndex:
      fillRect(itemBounds, selection)
    elif i == selector.hoverIndex:
      fillRect(itemBounds, surfaceHover)

    # Color swatch — diagonal split: background (top-left) + accent (bottom-right)
    let swatchX = itemBounds.x + 12
    let swatchY = itemY + 10
    let swatchSize = 16
    var bgColor = bg
    var accentColor = accent
    try:
      let t = loadThemeByName(themeName)
      bgColor = t.getColor(tcBackground)
      accentColor = t.getColor(tcAccent)
    except CatchableError:
      discard
    # Diagonal split: accent (top-left) + background (bottom-right)
    for dy in 0..<swatchSize:
      let splitX = swatchSize - 1 - dy
      # Accent fills the top-left wedge
      if splitX >= 0:
        fillRect(rect(swatchX, swatchY + dy, splitX + 1, 1), accentColor)
      # Background fills the bottom-right area
      if splitX + 1 < swatchSize:
        fillRect(rect(swatchX + splitX + 1, swatchY + dy, swatchSize - splitX - 1, 1), bgColor)
    # Swatch border
    fillRect(rect(swatchX, swatchY + swatchSize, swatchSize, 1), border)
    fillRect(rect(swatchX + swatchSize, swatchY, 1, swatchSize), border)

    # Theme name
    let displayName = themeName.capitalizeAscii()
    discard drawText(font, swatchX + swatchSize + 10, itemY + 9, displayName, text, color(0, 0, 0, 0))

    # Checkmark for active (saved) theme
    if themeName == selector.originalTheme:
      drawIcon(iiCheck, itemBounds.x + itemBounds.w - 28, itemY + 10)

  if selector.themes.len == 0:
    discard drawText(font, selector.bounds.x + 20, listY + 12, "No themes found", textSecondary, color(0, 0, 0, 0))

  # Footer hint
  let hintY = selector.bounds.y + selector.bounds.h - 24
  discard drawText(font, selector.bounds.x + 16, hintY,
                   "↑↓ to preview  ·  Enter to apply  ·  Esc to cancel", textSecondary, color(0, 0, 0, 0))

## Location Picker - overlay for choosing from multiple LSP locations

import uirelays
import uirelays/[coords, screen, input]
import theme, icons
import ../core/types

const
  PickerWidth = 560
  PickerHeight = 360
  ItemHeight = 36
  HeaderHeight = 48
  MaxVisibleItems = 8

type
  LocationItem* = object
    display*: string
    loc*: Location

  LocationPicker* = ref object
    items*: seq[LocationItem]
    selectedIndex*: int
    hoverIndex*: int
    isVisible*: bool
    anchorX*, anchorY*: int
    bounds*: coords.Rect
    onSelect*: proc(loc: Location)
    onCancel*: proc()

proc newLocationPicker*(): LocationPicker =
  LocationPicker(
    items: @[],
    selectedIndex: 0,
    hoverIndex: -1,
    isVisible: false,
    bounds: rect(0, 0, PickerWidth, PickerHeight)
  )

proc updateLayout*(picker: LocationPicker, viewport: coords.Rect) =
  # Position near the anchor (cursor), similar to hover tooltip
  var x = picker.anchorX + 12
  var y = picker.anchorY + 12
  if x + PickerWidth > viewport.x + viewport.w:
    x = max(viewport.x + 4, picker.anchorX - PickerWidth - 4)
  if y + PickerHeight > viewport.y + viewport.h:
    y = max(viewport.y + 4, picker.anchorY - PickerHeight - 4)
  if x < viewport.x + 4: x = viewport.x + 4
  if y < viewport.y + 4: y = viewport.y + 4
  picker.bounds = rect(x, y, PickerWidth, PickerHeight)

proc show*(picker: LocationPicker, items: seq[LocationItem], anchorX, anchorY: int) =
  picker.items = items
  picker.selectedIndex = 0
  picker.hoverIndex = -1
  picker.anchorX = anchorX
  picker.anchorY = anchorY
  picker.isVisible = true

proc hide*(picker: LocationPicker) =
  picker.isVisible = false
  picker.hoverIndex = -1

proc selectCurrent*(picker: LocationPicker) =
  if picker.selectedIndex >= 0 and picker.selectedIndex < picker.items.len:
    let item = picker.items[picker.selectedIndex]
    if picker.onSelect != nil:
      picker.onSelect(item.loc)
  picker.hide()

proc cancel*(picker: LocationPicker) =
  if picker.onCancel != nil:
    picker.onCancel()
  picker.hide()

proc handleInput*(picker: LocationPicker, e: Event): bool =
  if not picker.isVisible:
    return false
  case e.kind
  of KeyDownEvent:
    case e.key
    of KeyEsc:
      picker.cancel()
      return true
    of KeyEnter:
      picker.selectCurrent()
      return true
    of KeyUp:
      if picker.selectedIndex > 0:
        picker.selectedIndex -= 1
      return true
    of KeyDown:
      let maxIdx = picker.items.len - 1
      if picker.selectedIndex < maxIdx:
        picker.selectedIndex += 1
      return true
    else:
      return false
  of MouseDownEvent:
    let mousePos = point(e.x, e.y)
    if not picker.bounds.contains(mousePos):
      picker.cancel()
      return true
    let listY = picker.bounds.y + HeaderHeight
    let listH = min(MaxVisibleItems, picker.items.len) * ItemHeight
    let listBounds = rect(picker.bounds.x, listY, picker.bounds.w, listH)
    if listBounds.contains(mousePos):
      let relativeY = mousePos.y - listY
      let index = relativeY div ItemHeight
      if index >= 0 and index < picker.items.len:
        picker.selectedIndex = index
        picker.selectCurrent()
      return true
    return true
  of MouseMoveEvent:
    let mousePos = point(e.x, e.y)
    if not picker.bounds.contains(mousePos):
      picker.hoverIndex = -1
      return false
    let listY = picker.bounds.y + HeaderHeight
    let listH = min(MaxVisibleItems, picker.items.len) * ItemHeight
    let listBounds = rect(picker.bounds.x, listY, picker.bounds.w, listH)
    if listBounds.contains(mousePos):
      let relativeY = mousePos.y - listY
      let index = relativeY div ItemHeight
      if index >= 0 and index < picker.items.len:
        picker.hoverIndex = index
      else:
        picker.hoverIndex = -1
    else:
      picker.hoverIndex = -1
    return true
  else:
    discard
  false

proc render*(picker: LocationPicker, font: Font, viewport: coords.Rect) =
  if not picker.isVisible:
    return
  picker.updateLayout(viewport)

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
  fillRect(picker.bounds, surface)
  fillRect(rect(picker.bounds.x, picker.bounds.y + picker.bounds.h - 1, picker.bounds.w, 1), border)

  # Header
  let headerBounds = rect(picker.bounds.x, picker.bounds.y, picker.bounds.w, HeaderHeight)
  fillRect(headerBounds, bg)
  fillRect(rect(headerBounds.x, headerBounds.y + headerBounds.h - 1, headerBounds.w, 1), border)
  discard drawText(font, headerBounds.x + 16, headerBounds.y + 14,
                   "Select Definition (" & $picker.items.len & ")", text, color(0, 0, 0, 0))

  # Location list
  let listY = picker.bounds.y + HeaderHeight
  let maxItems = min(MaxVisibleItems, picker.items.len)
  for i in 0..<maxItems:
    let item = picker.items[i]
    let itemY = listY + i * ItemHeight
    let itemBounds = rect(picker.bounds.x + 1, itemY, picker.bounds.w - 2, ItemHeight)

    # Selection / hover background
    if i == picker.selectedIndex:
      fillRect(itemBounds, selection)
    elif i == picker.hoverIndex:
      fillRect(itemBounds, surfaceHover)

    drawIcon(iiFile, itemBounds.x + 12, itemY + 10)
    discard drawText(font, itemBounds.x + 36, itemY + 9, item.display, text, color(0, 0, 0, 0))

  if picker.items.len == 0:
    discard drawText(font, picker.bounds.x + 20, listY + 12, "No locations found", textSecondary, color(0, 0, 0, 0))

  # Footer hint
  let hintY = picker.bounds.y + picker.bounds.h - 24
  discard drawText(font, picker.bounds.x + 16, hintY,
                   "↑↓ to navigate  ·  Enter to open  ·  Esc to cancel", textSecondary, color(0, 0, 0, 0))

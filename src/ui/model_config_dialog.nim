## Model Configuration Dialog
## Toggle which built-in agent models appear in the model selection menu.

import uirelays
import uirelays/screen
import uirelays/input
import theme
import std/[sequtils, strutils, sets]

type
  ModelConfigItem* = object
    providerId*: string
    model*: string
    label*: string
    enabled*: bool

  ModelConfigDialog* = ref object
    title*: string
    items*: seq[ModelConfigItem]
    isVisible*: bool
    bounds*: Rect
    font*: Font
    selectedIndex*: int
    scrollOffset*: int
    onResult*: proc(confirmed: bool, enabledModels: seq[string])

const
  DialogWidth = 420
  DialogHeight = 360
  ItemHeight = 26
  MaxVisibleItems = 10

proc newModelConfigDialog*(font: Font): ModelConfigDialog =
  ModelConfigDialog(
    title: "Configure Models",
    items: @[],
    isVisible: false,
    bounds: rect(0, 0, DialogWidth, DialogHeight),
    font: font,
    selectedIndex: 0,
    scrollOffset: 0,
    onResult: nil
  )

proc setModels*(dialog: ModelConfigDialog, allModels: seq[tuple[providerId, model, label: string]], enabledModels: seq[string]) =
  dialog.items = @[]
  let enabledSet = enabledModels.toHashSet()
  for m in allModels:
    let id = m.providerId & "/" & m.model
    dialog.items.add(ModelConfigItem(
      providerId: m.providerId,
      model: m.model,
      label: m.label,
      enabled: enabledSet.contains(id) or enabledModels.len == 0
    ))
  dialog.selectedIndex = 0
  dialog.scrollOffset = 0

proc centerOnScreen*(dialog: ModelConfigDialog, screenWidth, screenHeight: int) =
  dialog.bounds.x = (screenWidth - dialog.bounds.w) div 2
  dialog.bounds.y = (screenHeight - dialog.bounds.h) div 2

proc show*(dialog: ModelConfigDialog) =
  dialog.isVisible = true

proc hide*(dialog: ModelConfigDialog) =
  dialog.isVisible = false

proc confirm(dialog: ModelConfigDialog) =
  if dialog.onResult != nil:
    var enabled: seq[string]
    for item in dialog.items:
      if item.enabled:
        enabled.add(item.providerId & "/" & item.model)
    dialog.onResult(true, enabled)
  dialog.hide()

proc cancel(dialog: ModelConfigDialog) =
  if dialog.onResult != nil:
    dialog.onResult(false, @[])
  dialog.hide()

proc handleInput*(dialog: ModelConfigDialog, event: Event): bool =
  if not dialog.isVisible:
    return false
  case event.kind
  of KeyDownEvent:
    case event.key
    of KeyEsc:
      dialog.cancel()
      return true
    of KeyEnter:
      dialog.confirm()
      return true
    of KeyUp:
      if dialog.selectedIndex > 0:
        dec dialog.selectedIndex
      if dialog.selectedIndex < dialog.scrollOffset:
        dialog.scrollOffset = dialog.selectedIndex
      return true
    of KeyDown:
      if dialog.selectedIndex < dialog.items.len - 1:
        inc dialog.selectedIndex
      let maxScroll = max(0, dialog.items.len - MaxVisibleItems)
      if dialog.selectedIndex >= dialog.scrollOffset + MaxVisibleItems:
        dialog.scrollOffset = min(dialog.selectedIndex - MaxVisibleItems + 1, maxScroll)
      return true
    of KeySpace:
      if dialog.selectedIndex >= 0 and dialog.selectedIndex < dialog.items.len:
        dialog.items[dialog.selectedIndex].enabled = not dialog.items[dialog.selectedIndex].enabled
      return true
    else:
      discard
  of MouseDownEvent:
    # Click outside = cancel
    if event.x < dialog.bounds.x or event.x >= dialog.bounds.x + dialog.bounds.w or
       event.y < dialog.bounds.y or event.y >= dialog.bounds.y + dialog.bounds.h:
      dialog.cancel()
      return true
    # Check item click
    let listY = dialog.bounds.y + 50
    let relY = event.y - listY
    if relY >= 0:
      let idx = dialog.scrollOffset + relY div ItemHeight
      if idx >= 0 and idx < dialog.items.len:
        dialog.selectedIndex = idx
        dialog.items[idx].enabled = not dialog.items[idx].enabled
      return true
  else:
    discard
  true

proc render*(dialog: ModelConfigDialog, viewportW, viewportH: int) =
  if not dialog.isVisible:
    return
  let bg = currentTheme.getColor(tcSurface)
  let borderC = currentTheme.getColor(tcBorder)
  let textC = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let accentC = currentTheme.getColor(tcAccent)
  let fm = dialog.font.getFontMetrics()

  fillRect(rect(0, 0, viewportW, viewportH), color(0, 0, 0, 128))
  fillRect(dialog.bounds, bg)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y, dialog.bounds.w, 1), borderC)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y + dialog.bounds.h - 1, dialog.bounds.w, 1), borderC)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y, 1, dialog.bounds.h), borderC)
  fillRect(rect(dialog.bounds.x + dialog.bounds.w - 1, dialog.bounds.y, 1, dialog.bounds.h), borderC)

  let titleH = measureText(dialog.font, dialog.title).h
  discard drawText(dialog.font, dialog.bounds.x + 16, dialog.bounds.y + 12, dialog.title, textC, color(0,0,0,0))

  let listX = dialog.bounds.x + 16
  let listY = dialog.bounds.y + 16 + titleH + 12
  let listW = dialog.bounds.w - 32
  let listH = ItemHeight * MaxVisibleItems
  fillRect(rect(listX, listY, listW, listH), currentTheme.getColor(tcBackground))

  let visibleEnd = min(dialog.items.len, dialog.scrollOffset + MaxVisibleItems)
  for i in dialog.scrollOffset ..< visibleEnd:
    let item = dialog.items[i]
    let y = listY + (i - dialog.scrollOffset) * ItemHeight
    if i == dialog.selectedIndex:
      fillRect(rect(listX, y, listW, ItemHeight), accentC)
    let checkbox = if item.enabled: "[x] " else: "[ ] "
    discard drawText(dialog.font, listX + 8, y + 4, checkbox & item.label, textC, color(0,0,0,0))

  # Scrollbar indicator
  if dialog.items.len > MaxVisibleItems:
    let scrollH = listH * MaxVisibleItems div dialog.items.len
    let scrollY = listY + (dialog.scrollOffset * listH div dialog.items.len)
    fillRect(rect(dialog.bounds.x + dialog.bounds.w - 12, scrollY, 4, scrollH), textMuted)

  let hint = "Space/Click to toggle, Enter to save, Esc to cancel"
  let hintH = measureText(dialog.font, hint).h
  discard drawText(dialog.font, dialog.bounds.x + 16, dialog.bounds.y + dialog.bounds.h - 12 - hintH, hint, textMuted, color(0,0,0,0))

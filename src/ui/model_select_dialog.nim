## Single-select model picker dialog
## Modal dialog for choosing one built-in model (e.g. setting a preset).

import std/[strutils]
import uirelays
import uirelays/screen
import uirelays/input
import theme

const
  DialogWidth = 360
  DialogHeight = 420
  ItemHeight = 28
  ListPadding = 8

type
  ModelSelectItem* = object
    providerId*: string
    model*: string
    label*: string

  ModelSelectDialog* = ref object
    title*: string
    items*: seq[ModelSelectItem]
    isVisible*: bool
    bounds*: Rect
    font*: Font
    selectedIndex*: int
    scrollOffset*: int
    onResult*: proc(confirmed: bool, providerId, model: string)

proc newModelSelectDialog*(font: Font): ModelSelectDialog =
  ModelSelectDialog(
    title: "Select Model",
    items: @[],
    isVisible: false,
    bounds: rect(0, 0, DialogWidth, DialogHeight),
    font: font,
    selectedIndex: 0,
    scrollOffset: 0,
    onResult: nil
  )

proc centerOnScreen*(dialog: ModelSelectDialog, screenWidth, screenHeight: int) =
  dialog.bounds.x = (screenWidth - dialog.bounds.w) div 2
  dialog.bounds.y = (screenHeight - dialog.bounds.h) div 2

proc show*(dialog: ModelSelectDialog) =
  dialog.isVisible = true
  dialog.selectedIndex = 0
  dialog.scrollOffset = 0

proc hide*(dialog: ModelSelectDialog) =
  dialog.isVisible = false

proc setModels*(dialog: ModelSelectDialog, allModels: seq[tuple[providerId, model, label: string]], enabledModels: seq[string]) =
  dialog.items = @[]
  let enabled = enabledModels.len == 0
  for m in allModels:
    if enabled or (m.providerId & "/" & m.model) in enabledModels:
      dialog.items.add(ModelSelectItem(providerId: m.providerId, model: m.model, label: m.label))
  if dialog.selectedIndex >= dialog.items.len:
    dialog.selectedIndex = max(0, dialog.items.len - 1)

proc handleInput*(dialog: ModelSelectDialog, event: Event): bool =
  if not dialog.isVisible:
    return false

  case event.kind
  of KeyDownEvent:
    case event.key
    of KeyEsc:
      if dialog.onResult != nil:
        dialog.onResult(false, "", "")
      dialog.hide()
      return true
    of KeyEnter:
      if dialog.items.len > 0 and dialog.onResult != nil:
        let item = dialog.items[dialog.selectedIndex]
        dialog.onResult(true, item.providerId, item.model)
      dialog.hide()
      return true
    of KeyUp:
      if dialog.selectedIndex > 0:
        dec dialog.selectedIndex
      dialog.scrollOffset = min(dialog.scrollOffset, dialog.selectedIndex)
      return true
    of KeyDown:
      if dialog.selectedIndex < dialog.items.len - 1:
        inc dialog.selectedIndex
      return true
    else:
      discard
  of MouseDownEvent:
    if event.x < dialog.bounds.x or event.x >= dialog.bounds.x + dialog.bounds.w or
       event.y < dialog.bounds.y or event.y >= dialog.bounds.y + dialog.bounds.h:
      if dialog.onResult != nil:
        dialog.onResult(false, "", "")
      dialog.hide()
      return true
    let listY = dialog.bounds.y + 44
    let listH = dialog.bounds.h - 44 - 16
    let relativeY = event.y - listY + dialog.scrollOffset * ItemHeight
    let index = relativeY div ItemHeight
    if index >= 0 and index < dialog.items.len:
      dialog.selectedIndex = index
      if dialog.onResult != nil:
        let item = dialog.items[index]
        dialog.onResult(true, item.providerId, item.model)
      dialog.hide()
      return true
  of MouseWheelEvent:
    let maxScroll = max(0, dialog.items.len - (dialog.bounds.h - 44 - 16) div ItemHeight)
    dialog.scrollOffset = clamp(dialog.scrollOffset - event.y, 0, maxScroll)
    return true
  else:
    discard
  true

proc render*(dialog: ModelSelectDialog, viewportW, viewportH: int) =
  if not dialog.isVisible:
    return

  let bg = currentTheme.getColor(tcSurface)
  let borderC = currentTheme.getColor(tcBorder)
  let textC = currentTheme.getColor(tcText)
  let textMuted = currentTheme.getColor(tcTextSecondary)
  let accentC = currentTheme.getColor(tcAccent)
  let fm = dialog.font.getFontMetrics()

  # Dim background
  fillRect(rect(0, 0, viewportW, viewportH), color(0, 0, 0, 128))

  # Dialog background
  fillRect(dialog.bounds, bg)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y, dialog.bounds.w, 1), borderC)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y + dialog.bounds.h - 1, dialog.bounds.w, 1), borderC)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y, 1, dialog.bounds.h), borderC)
  fillRect(rect(dialog.bounds.x + dialog.bounds.w - 1, dialog.bounds.y, 1, dialog.bounds.h), borderC)

  # Title
  discard dialog.font.drawText(dialog.bounds.x + 16, dialog.bounds.y + 12, dialog.title, textC, bg)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y + 40, dialog.bounds.w, 1), borderC)

  # List
  let listX = dialog.bounds.x + ListPadding
  let listY = dialog.bounds.y + 44
  let listW = dialog.bounds.w - ListPadding * 2
  let listH = dialog.bounds.h - 44 - 16

  var y = listY - dialog.scrollOffset * ItemHeight
  for i, item in dialog.items:
    if y + ItemHeight > listY and y < listY + listH:
      if i == dialog.selectedIndex:
        fillRect(rect(listX, y, listW, ItemHeight), accentC)
        discard dialog.font.drawText(listX + 8, y + 6, item.label, color(255, 255, 255, 255), accentC)
      else:
        discard dialog.font.drawText(listX + 8, y + 6, item.label, textC, bg)
    y += ItemHeight

  # Hint
  let hint = "Enter to select, Esc to cancel"
  let hintW = dialog.font.measureText(hint).w
  discard dialog.font.drawText(dialog.bounds.x + (dialog.bounds.w - hintW) div 2,
                               dialog.bounds.y + dialog.bounds.h - 14 - fm.lineHeight,
                               hint, textMuted, bg)

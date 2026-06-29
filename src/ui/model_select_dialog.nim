## Unified model/preset picker dialog
##
## Shows an "Auto" item plus all built-in models. Models assigned to the
## lightweight/heavyweight preset get a badge. Selecting a model triggers an
## action menu (Set as Light / Set as Heavy / Set API Key) via callback.

import std/[strutils]
import uirelays
import uirelays/screen
import uirelays/input
import theme

const
  DialogWidth = 420
  DialogHeight = 460
  ItemHeight = 28
  ListPadding = 8
  BadgeMargin = 8
  BadgeSpacing = 4

type
  ModelSelectItemKind* = enum
    msiAuto
    msiModel

  ModelSelectItem* = object
    kind*: ModelSelectItemKind
    providerId*: string
    model*: string
    label*: string

  ModelSelectDialog* = ref object
    title*: string
    items*: seq[ModelSelectItem]
    isVisible*: bool
    bounds*: Rect
    font*: Font
    lightProvider*: string
    lightModel*: string
    heavyProvider*: string
    heavyModel*: string
    selectedIndex*: int
    scrollOffset*: int
    enabledModels*: seq[string]
    onSelectAuto*: proc()
    onSelectModel*: proc(providerId, model: string)
    onToggleModel*: proc(providerId, model: string, enabled: bool)

proc newModelSelectDialog*(font: Font): ModelSelectDialog =
  ModelSelectDialog(
    title: "Select Model",
    items: @[],
    isVisible: false,
    bounds: rect(0, 0, DialogWidth, DialogHeight),
    font: font,
    lightProvider: "",
    lightModel: "",
    heavyProvider: "",
    heavyModel: "",
    selectedIndex: 0,
    scrollOffset: 0,
    enabledModels: @[],
    onSelectAuto: nil,
    onSelectModel: nil,
    onToggleModel: nil
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

proc setModels*(dialog: ModelSelectDialog,
                allModels: seq[tuple[providerId, model, label: string]]) =
  dialog.items = @[]
  dialog.items.add(ModelSelectItem(kind: msiAuto, providerId: "", model: "", label: "Auto"))
  for m in allModels:
    dialog.items.add(ModelSelectItem(kind: msiModel, providerId: m.providerId, model: m.model, label: m.label))
  if dialog.selectedIndex >= dialog.items.len:
    dialog.selectedIndex = max(0, dialog.items.len - 1)

proc isLightModel*(dialog: ModelSelectDialog, providerId, model: string): bool =
  providerId.len > 0 and model.len > 0 and
    providerId == dialog.lightProvider and model == dialog.lightModel

proc isHeavyModel*(dialog: ModelSelectDialog, providerId, model: string): bool =
  providerId.len > 0 and model.len > 0 and
    providerId == dialog.heavyProvider and model == dialog.heavyModel

proc isModelEnabled*(dialog: ModelSelectDialog, providerId, model: string): bool =
  if dialog.enabledModels.len == 0:
    return true
  return (providerId & "/" & model) in dialog.enabledModels

proc listY(dialog: ModelSelectDialog): int =
  dialog.bounds.y + 44

proc listH(dialog: ModelSelectDialog): int =
  dialog.bounds.h - 44 - 16

proc maxScroll(dialog: ModelSelectDialog): int =
  max(0, dialog.items.len - dialog.listH div ItemHeight)

proc handleInput*(dialog: ModelSelectDialog, event: Event): bool =
  if not dialog.isVisible:
    return false

  case event.kind
  of KeyDownEvent:
    case event.key
    of KeyEsc:
      dialog.hide()
      return true
    of KeyEnter:
      if dialog.selectedIndex >= 0 and dialog.selectedIndex < dialog.items.len:
        let item = dialog.items[dialog.selectedIndex]
        if item.kind == msiAuto:
          if dialog.onSelectAuto != nil:
            dialog.onSelectAuto()
        else:
          if dialog.onSelectModel != nil:
            dialog.onSelectModel(item.providerId, item.model)
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
      dialog.scrollOffset = max(dialog.scrollOffset, dialog.selectedIndex - dialog.listH div ItemHeight + 1)
      return true
    else:
      discard
  of MouseDownEvent:
    if event.x < dialog.bounds.x or event.x >= dialog.bounds.x + dialog.bounds.w or
       event.y < dialog.bounds.y or event.y >= dialog.bounds.y + dialog.bounds.h:
      dialog.hide()
      return true

    # List item clicks
    let listY0 = dialog.listY
    let listH0 = dialog.listH
    if event.y >= listY0 and event.y < listY0 + listH0:
      let relativeY = event.y - listY0 + dialog.scrollOffset * ItemHeight
      let index = relativeY div ItemHeight
      if index >= 0 and index < dialog.items.len:
        let item = dialog.items[index]
        if item.kind == msiAuto:
          if dialog.onSelectAuto != nil:
            dialog.onSelectAuto()
        else:
          if dialog.onSelectModel != nil:
            dialog.onSelectModel(item.providerId, item.model)
        dialog.hide()
        return true
    return true
  of MouseWheelEvent:
    dialog.scrollOffset = clamp(dialog.scrollOffset - event.y, 0, dialog.maxScroll)
    return true
  else:
    discard
  true

proc renderBadgeRight(font: Font, text: string, rightX, y: int, bg, fg: Color): int =
  ## Render a small badge aligned to ``rightX`` and return the left edge x.
  let padX = 6
  let size = font.measureText(text)
  let w = size.w + padX * 2
  let x = rightX - w
  fillRect(rect(x, y, w, size.h + 4), bg)
  discard font.drawText(x + padX, y + 2, text, fg, bg)
  return x

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
  let listY0 = dialog.listY
  let listW = dialog.bounds.w - ListPadding * 2
  let listH0 = dialog.listH

  var y = listY0 - dialog.scrollOffset * ItemHeight
  for i, item in dialog.items:
    if y + ItemHeight > listY0 and y < listY0 + listH0:
      let isSelected = i == dialog.selectedIndex
      let isEnabled = item.kind == msiAuto or dialog.isModelEnabled(item.providerId, item.model)
      let rowBg = if isSelected: accentC else: bg
      let rowFg = if isSelected:
        color(255, 255, 255, 255)
      elif not isEnabled:
        textMuted
      else:
        textC
      fillRect(rect(listX, y, listW, ItemHeight), rowBg)
      let labelX = listX + 8
      discard dialog.font.drawText(labelX, y + 6, item.label, rowFg, rowBg)

      # Badges for Light / Heavy assignments and disabled indicator
      if item.kind == msiModel:
        var badgeRightX = listX + listW - BadgeMargin
        if not isEnabled:
          badgeRightX = renderBadgeRight(dialog.font, "Disabled",
                                         badgeRightX, y + 4,
                                         if isSelected: color(255, 255, 255, 60) else: color(120, 120, 120, 60),
                                         rowFg) - BadgeSpacing
        if dialog.isHeavyModel(item.providerId, item.model):
          badgeRightX = renderBadgeRight(dialog.font, "Heavy",
                                         badgeRightX, y + 4,
                                         if isSelected: color(255, 255, 255, 60) else: color(accentC.r, accentC.g, accentC.b, 40),
                                         rowFg) - BadgeSpacing
        if dialog.isLightModel(item.providerId, item.model):
          discard renderBadgeRight(dialog.font, "Light",
                                   badgeRightX, y + 4,
                                   if isSelected: color(255, 255, 255, 60) else: color(accentC.r, accentC.g, accentC.b, 40),
                                   rowFg)
    y += ItemHeight

  # Hint
  let hint = "Enter to select, Esc to cancel"
  let hintW = dialog.font.measureText(hint).w
  discard dialog.font.drawText(dialog.bounds.x + (dialog.bounds.w - hintW) div 2,
                               dialog.bounds.y + dialog.bounds.h - 14 - fm.lineHeight,
                               hint, textMuted, bg)

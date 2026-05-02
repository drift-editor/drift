## Reusable UI Widget Components

import uirelays
import uirelays/[coords, screen]
import ../ui/theme, ../ui/icons

type
  InputBox* = object
    text*: string
    placeholder*: string
    icon*: IconId
    focused*: bool
    showClear*: bool
    cursorPos*: int = 0

  InputBoxState* = object
    text*: string
    placeholder*: string
    icon*: IconId
    focused*: bool
    showClear*: bool
    hovered*: bool

  Toggle* = object
    active*: bool
    hovered*: bool

  IconButton* = object
    icon*: IconId
    hovered*: bool

  ActionButton* = object
    text*: string
    hovered*: bool

const
  WidgetPadding* = 4
  InputHeight* = 26
  ToggleSize* = 20

proc newInputBox*(text = "", placeholder = "", icon = iiSearch, cursorPos = 0): InputBox =
  InputBox(text: text, placeholder: placeholder, icon: icon, cursorPos: cursorPos)

proc render*(box: InputBox; font: Font; bounds: Rect; hovered, blink: bool; cursorPosOverride: int = -1; accent, bg, borderC, textC, placeholderC: Color) =
  let inputBg = if box.focused: bg else: currentTheme.getColor(tcSurface)
  fillRect(bounds, inputBg)
  fillRect(rect(bounds.x, bounds.y + bounds.h - 1, bounds.w, 1),
         if box.focused: accent else: borderC)

  if box.icon != iiNone:
    drawIcon(box.icon, bounds.x + 24, bounds.y + (bounds.h - 16) div 2)

  let clearW = if box.showClear: 20 + WidgetPadding * 2 else: 0
  let textAreaW = bounds.w - 24 - 20 - WidgetPadding * 2 - clearW
  let display = if box.text.len > 0: box.text else: box.placeholder
  let color = if box.text.len > 0: textC else: placeholderC
  var textClip = display
  while textClip.len > 0 and measureText(font, textClip).w > textAreaW:
    textClip.setLen(textClip.len - 1)
  let textX = bounds.x + 24 + 18
  let textH = measureText(font, display).h
  let textY = bounds.y + (bounds.h - textH) div 2
  discard drawText(font, textX, textY, textClip, color, inputBg)

  if box.focused and blink:
    let cpos = clamp(cursorPosOverride, 0, box.text.len)
    var cursorText = box.text[0..<min(cpos, box.text.len)]
    while cursorText.len > 0 and measureText(font, cursorText).w > textAreaW:
      cursorText.setLen(cursorText.len - 1)
    let cursorX = textX + measureText(font, cursorText).w
    let cursorH = measureText(font, "M").h
    let cursorY = bounds.y + (bounds.h - cursorH) div 2
    fillRect(rect(cursorX, cursorY, 2, cursorH), textC)

  if box.showClear and box.text.len > 0:
    let textEndX = bounds.x + 24 + 18 + textAreaW
    let clearBounds = rect(textEndX + 4, bounds.y + (bounds.h - 20) div 2, 20, 20)
    if hovered:
      fillRect(clearBounds, currentTheme.getColor(tcSurfaceHover))
    drawIconCentered(iiClose, clearBounds)

proc handleMouse*(box: var InputBoxState; e: Event; bounds: Rect; editableWidth: int): bool =
  if e.kind == MouseDownEvent or e.kind == MouseMoveEvent:
    box.hovered = bounds.contains(point(e.x, e.y))
  if e.kind == MouseDownEvent and box.hovered:
    if box.showClear and box.text.len > 0 and e.x >= bounds.x + bounds.w - 20 - WidgetPadding:
      box.text.setLen(0)
      return true
    if e.x >= bounds.x + 24 + 18 and e.x < bounds.x + 24 + 18 + editableWidth:
      return true
  false

proc newToggle*(active = false): Toggle =
  Toggle(active: active)

proc render*(toggle: Toggle; font: Font; bounds: Rect; text: string; hovered: bool; accent, bg, bgHover, textC: Color) =
  let toggleBg = if toggle.active: accent
               elif hovered: bgHover
               else: bg
  fillRect(bounds, toggleBg)
  let fg = if toggle.active: bg else: textC
  if text.len > 0:
    let th = measureText(font, text).h
    discard drawText(font, bounds.x + 4, bounds.y + (bounds.h - th) div 2, text, fg, toggleBg)

proc handleMouse*(toggle: var Toggle; e: Event; bounds: Rect): bool =
  if e.kind == MouseDownEvent and bounds.contains(point(e.x, e.y)):
    toggle.active = not toggle.active
    return true
  if e.kind == MouseMoveEvent:
    toggle.hovered = bounds.contains(point(e.x, e.y))
  false

proc newIconButton*(icon: IconId): IconButton =
  IconButton(icon: icon)

proc render*(btn: IconButton; bounds: Rect; hovered: bool; bgHover: Color) =
  if hovered:
    fillRect(bounds, bgHover)
  drawIconCentered(btn.icon, bounds)

proc handleMouse*(btn: var IconButton; e: Event; bounds: Rect): bool =
  if e.kind == MouseDownEvent or e.kind == MouseMoveEvent:
    btn.hovered = bounds.contains(point(e.x, e.y))
  false

proc newActionButton*(text: string): ActionButton =
  ActionButton(text: text)

proc render*(btn: ActionButton; font: Font; bounds: Rect; hovered: bool; bg, bgHover, textC: Color) =
  let buttonBg = if hovered: bgHover else: bg
  fillRect(bounds, buttonBg)
  let th = measureText(font, btn.text).h
  let tx = bounds.x + (bounds.w - measureText(font, btn.text).w) div 2
  let ty = bounds.y + (bounds.h - th) div 2
  discard drawText(font, tx, ty, btn.text, textC, buttonBg)

proc handleMouse*(btn: var ActionButton; e: Event; bounds: Rect): bool =
  if e.kind == MouseDownEvent and bounds.contains(point(e.x, e.y)):
    return true
  if e.kind == MouseMoveEvent:
    btn.hovered = bounds.contains(point(e.x, e.y))
  false
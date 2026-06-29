## Dialog Component
## Modal dialogs for user confirmation and input (uirelays version)

import std/unicode
import uirelays
import uirelays/screen
import uirelays/input
import theme

type
  DialogResult* = enum
    drNone
    drOk
    drCancel
    drYes
    drNo
    drSave
    drDontSave

  DialogButton* = object
    label*: string
    result*: DialogResult
    isDefault*: bool
    isCancel*: bool

  Dialog* = ref object
    title*: string
    message*: string
    buttons*: seq[DialogButton]
    isVisible*: bool
    bounds*: Rect
    font*: Font
    onResult*: proc(result: DialogResult)

# Button Factory

proc newButton(label: string, btnResult: DialogResult, isDefault = false, isCancel = false): DialogButton =
  DialogButton(label: label, result: btnResult, isDefault: isDefault, isCancel: isCancel)

# Dialog Creation

proc newDialog*(title, message: string, font: Font): Dialog =
  Dialog(
    title: title,
    message: message,
    buttons: @[],
    isVisible: false,
    bounds: rect(0, 0, 400, 150),
    font: font,
    onResult: nil
  )

proc centerOnScreen*(dialog: Dialog, screenWidth, screenHeight: int) =
  dialog.bounds.x = (screenWidth - dialog.bounds.w) div 2
  dialog.bounds.y = (screenHeight - dialog.bounds.h) div 2

# Pre-configured Dialogs

proc newConfirmDialog*(title, message: string, font: Font, onResult: proc(result: DialogResult)): Dialog =
  let dialog = newDialog(title, message, font)
  dialog.buttons = @[
    newButton("Yes", drYes, isDefault = true),
    newButton("No", drNo),
    newButton("Cancel", drCancel, isCancel = true)
  ]
  dialog.onResult = onResult
  dialog

proc newOkCancelDialog*(title, message: string, font: Font, onResult: proc(result: DialogResult)): Dialog =
  let dialog = newDialog(title, message, font)
  dialog.buttons = @[
    newButton("OK", drOk, isDefault = true),
    newButton("Cancel", drCancel, isCancel = true)
  ]
  dialog.onResult = onResult
  dialog

proc newSaveDialog*(message: string, font: Font, onResult: proc(result: DialogResult)): Dialog =
  let dialog = newDialog("Unsaved Changes", message, font)
  dialog.buttons = @[
    newButton("Save", drSave, isDefault = true),
    newButton("Don't Save", drDontSave),
    newButton("Cancel", drCancel, isCancel = true)
  ]
  dialog.onResult = onResult
  dialog

# Show/Hide

proc show*(dialog: Dialog) =
  dialog.isVisible = true

proc hide*(dialog: Dialog) =
  dialog.isVisible = false

proc show*(dialog: Dialog, onResult: proc(result: DialogResult)) =
  dialog.onResult = onResult
  dialog.show()

# Input Handling

proc handleInput*(dialog: Dialog, event: Event): bool =
  if not dialog.isVisible:
    return false

  case event.kind
  of KeyDownEvent:
    case event.key
    of KeyEsc:
      for btn in dialog.buttons:
        if btn.isCancel:
          if dialog.onResult != nil:
            dialog.onResult(btn.result)
          dialog.hide()
          return true
    of KeyEnter:
      for btn in dialog.buttons:
        if btn.isDefault:
          if dialog.onResult != nil:
            dialog.onResult(btn.result)
          dialog.hide()
          return true
    else:
      discard

  of MouseDownEvent:
    if event.button == LeftButton:
      const
        ButtonWidth = 80
        ButtonHeight = 30
        ButtonSpacing = 10
      let totalWidth = dialog.buttons.len * (ButtonWidth + ButtonSpacing) - ButtonSpacing
      var buttonX = dialog.bounds.x + (dialog.bounds.w - totalWidth) div 2
      let buttonY = dialog.bounds.y + dialog.bounds.h - ButtonHeight - 20

      for btn in dialog.buttons:
        let btnBounds = rect(buttonX, buttonY, ButtonWidth, ButtonHeight)
        if event.x >= btnBounds.x and event.x < btnBounds.x + btnBounds.w and
           event.y >= btnBounds.y and event.y < btnBounds.y + btnBounds.h:
          if dialog.onResult != nil:
            dialog.onResult(btn.result)
          dialog.hide()
          return true
        buttonX += ButtonWidth + ButtonSpacing

      # Click outside dialog = cancel
      if event.x < dialog.bounds.x or event.x >= dialog.bounds.x + dialog.bounds.w or
         event.y < dialog.bounds.y or event.y >= dialog.bounds.y + dialog.bounds.h:
        for btn in dialog.buttons:
          if btn.isCancel:
            if dialog.onResult != nil:
              dialog.onResult(btn.result)
            dialog.hide()
            return true

  else:
    discard

  true  # Modal dialog captures all input

# Rendering

proc render*(dialog: Dialog, viewportW, viewportH: int) =
  if not dialog.isVisible:
    return

  # Dim background (cover entire screen)
  fillRect(rect(0, 0, viewportW, viewportH), color(0, 0, 0, 128))

  # Dialog background
  fillRect(dialog.bounds, currentTheme.getColor(tcSurface))

  # Border
  let b = dialog.bounds
  fillRect(rect(b.x,     b.y,      b.w, 2), currentTheme.getColor(tcBorder))
  fillRect(rect(b.x,     b.y + b.h - 2, b.w, 2), currentTheme.getColor(tcBorder))
  fillRect(rect(b.x,     b.y,      2, b.h), currentTheme.getColor(tcBorder))
  fillRect(rect(b.x + b.w - 2, b.y, 2, b.h), currentTheme.getColor(tcBorder))

  # Title
  discard drawText(dialog.font,
                   b.x + 16,
                   b.y + 12,
                   dialog.title,
                   currentTheme.getColor(tcText),
                   currentTheme.getColor(tcSurface))

  # Title separator
  fillRect(rect(b.x, b.y + 40, b.w, 1), currentTheme.getColor(tcBorder))

  # Message
  discard drawText(dialog.font,
                   b.x + 16,
                   b.y + 55,
                   dialog.message,
                   currentTheme.getColor(tcText),
                   currentTheme.getColor(tcSurface))

  # Buttons
  const
    ButtonWidth = 80
    ButtonHeight = 30
    ButtonSpacing = 10
  let totalWidth = dialog.buttons.len * (ButtonWidth + ButtonSpacing) - ButtonSpacing
  var buttonX = b.x + (b.w - totalWidth) div 2
  let buttonY = b.y + b.h - ButtonHeight - 20

  for btn in dialog.buttons:
    let btnBounds = rect(buttonX, buttonY, ButtonWidth, ButtonHeight)

    let bgColor = if btn.isDefault:
      currentTheme.getColor(tcAccent)
    else:
      currentTheme.getColor(tcSurfaceHover)
    fillRect(btnBounds, bgColor)

    # Button border
    fillRect(rect(btnBounds.x,     btnBounds.y,      btnBounds.w, 1), currentTheme.getColor(tcBorder))
    fillRect(rect(btnBounds.x,     btnBounds.y + btnBounds.h - 1, btnBounds.w, 1), currentTheme.getColor(tcBorder))
    fillRect(rect(btnBounds.x,     btnBounds.y,      1, btnBounds.h), currentTheme.getColor(tcBorder))
    fillRect(rect(btnBounds.x + btnBounds.w - 1, btnBounds.y, 1, btnBounds.h), currentTheme.getColor(tcBorder))

    let textColor = if btn.isDefault:
      currentTheme.getColor(tcBackground)
    else:
      currentTheme.getColor(tcText)

    let textWidth = btn.label.len * 7
    discard drawText(dialog.font,
                     btnBounds.x + (btnBounds.w - textWidth) div 2,
                     btnBounds.y + 7,
                     btn.label,
                     textColor,
                     bgColor)

    buttonX += ButtonWidth + ButtonSpacing

# Dialog Stack Manager

type
  DialogManager* = ref object
    dialogs*: seq[Dialog]

proc newDialogManager*(): DialogManager =
  DialogManager(dialogs: @[])

proc show*(manager: DialogManager, dialog: Dialog) =
  manager.dialogs.add(dialog)
  dialog.show()

proc hideTop*(manager: DialogManager) =
  if manager.dialogs.len > 0:
    let dialog = manager.dialogs.pop()
    dialog.hide()

proc hideAll*(manager: DialogManager) =
  for dialog in manager.dialogs:
    dialog.hide()
  manager.dialogs = @[]

proc handleInput*(manager: DialogManager, event: Event): bool =
  if manager.dialogs.len > 0:
    return manager.dialogs[^1].handleInput(event)
  false

proc render*(manager: DialogManager, viewportW, viewportH: int) =
  for dialog in manager.dialogs:
    dialog.render(viewportW, viewportH)

proc isModalActive*(manager: DialogManager): bool =
  manager.dialogs.len > 0

# Text Input Dialog

type
  InputDialog* = ref object
    title*: string
    prompt*: string
    text*: string
    isVisible*: bool
    bounds*: Rect
    font*: Font
    onResult*: proc(confirmed: bool, text: string)
    cursorVisible: bool
    lastBlinkTick: int

proc newInputDialog*(title, prompt: string, font: Font): InputDialog =
  InputDialog(
    title: title,
    prompt: prompt,
    text: "",
    isVisible: false,
    bounds: rect(0, 0, 400, 140),
    font: font,
    onResult: nil
  )

proc centerOnScreen*(dialog: InputDialog, screenWidth, screenHeight: int) =
  dialog.bounds.x = (screenWidth - dialog.bounds.w) div 2
  dialog.bounds.y = (screenHeight - dialog.bounds.h) div 2

proc show*(dialog: InputDialog) =
  dialog.isVisible = true
  dialog.cursorVisible = true
  dialog.lastBlinkTick = getTicks()

proc hide*(dialog: InputDialog) =
  dialog.isVisible = false

proc handleInput*(dialog: InputDialog, event: Event): bool =
  if not dialog.isVisible:
    return false
  case event.kind
  of KeyDownEvent:
    case event.key
    of KeyEsc:
      if dialog.onResult != nil:
        dialog.onResult(false, dialog.text)
      dialog.hide()
      return true
    of KeyEnter:
      if dialog.onResult != nil:
        dialog.onResult(true, dialog.text)
      dialog.hide()
      return true
    of KeyBackspace:
      if dialog.text.len > 0:
        let runes = dialog.text.toRunes()
        if runes.len > 0:
          var s = ""
          for i in 0 ..< runes.len - 1:
            s.add($runes[i])
          dialog.text = s
      dialog.cursorVisible = true
      dialog.lastBlinkTick = getTicks()
      return true
    of KeyV:
      let pasteMod = when defined(macosx): GuiPressed else: CtrlPressed
      if pasteMod in event.mods:
        let text = getClipboardText()
        if text.len > 0:
          dialog.text.add(text)
          dialog.cursorVisible = true
          dialog.lastBlinkTick = getTicks()
        return true
    else:
      discard
  of TextInputEvent:
    for c in event.text:
      if c == '\0': break
      dialog.text.add(c)
    dialog.cursorVisible = true
    dialog.lastBlinkTick = getTicks()
    return true
  of MouseDownEvent:
    # Click outside = cancel
    if event.x < dialog.bounds.x or event.x >= dialog.bounds.x + dialog.bounds.w or
       event.y < dialog.bounds.y or event.y >= dialog.bounds.y + dialog.bounds.h:
      if dialog.onResult != nil:
        dialog.onResult(false, dialog.text)
      dialog.hide()
      return true
  else:
    discard
  true

proc render*(dialog: InputDialog, viewportW, viewportH: int) =
  if not dialog.isVisible:
    return
  fillRect(rect(0, 0, viewportW, viewportH), color(0, 0, 0, 128))
  fillRect(dialog.bounds, currentTheme.getColor(tcSurface))
  let borderC = currentTheme.getColor(tcBorder)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y, dialog.bounds.w, 1), borderC)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y + dialog.bounds.h - 1, dialog.bounds.w, 1), borderC)
  fillRect(rect(dialog.bounds.x, dialog.bounds.y, 1, dialog.bounds.h), borderC)
  fillRect(rect(dialog.bounds.x + dialog.bounds.w - 1, dialog.bounds.y, 1, dialog.bounds.h), borderC)
  let titleH = measureText(dialog.font, dialog.title).h
  discard drawText(dialog.font, dialog.bounds.x + 16, dialog.bounds.y + 12, dialog.title, currentTheme.getColor(tcText), color(0,0,0,0))
  let promptH = measureText(dialog.font, dialog.prompt).h
  discard drawText(dialog.font, dialog.bounds.x + 16, dialog.bounds.y + 16 + titleH + 8, dialog.prompt, currentTheme.getColor(tcTextSecondary), color(0,0,0,0))
  let inputY = dialog.bounds.y + 16 + titleH + 8 + promptH + 12
  fillRect(rect(dialog.bounds.x + 16, inputY, dialog.bounds.w - 32, 28), currentTheme.getColor(tcBackground))
  discard drawText(dialog.font, dialog.bounds.x + 20, inputY + 4, dialog.text, currentTheme.getColor(tcText), currentTheme.getColor(tcBackground))
  let ticks = getTicks()
  if ticks - dialog.lastBlinkTick > 500:
    dialog.cursorVisible = not dialog.cursorVisible
    dialog.lastBlinkTick = ticks
  if dialog.cursorVisible:
    let textW = measureText(dialog.font, dialog.text).w
    let cursorX = dialog.bounds.x + 20 + textW
    fillRect(rect(cursorX, inputY + 4, 2, measureText(dialog.font, "|").h), currentTheme.getColor(tcText))
  let hint = "Press Enter to confirm, Esc to cancel"
  let hintH = measureText(dialog.font, hint).h
  discard drawText(dialog.font, dialog.bounds.x + 16, dialog.bounds.y + dialog.bounds.h - 12 - hintH, hint, currentTheme.getColor(tcTextSecondary), color(0,0,0,0))

# INTEGRATION_NOTES
# This module is a port of src_old_backup/ui/components/dialog.nim to uirelays.
# Changes made:
#   - Uses uirelays/screen.Rect (x,y,w,h as int) instead of float32-based Rect.
#   - Uses uirelays/screen.Color (uint8 r,g,b,a).
#   - Rendering uses global fillRect and drawText (with Font + fg/bg colors).
#   - handleInput uses uirelays/input.Event instead of the old InputEvent type.
#   - centerOnScreen takes int parameters instead of float32.
#   - Removed drawRectOutline; borders are drawn manually with fillRect.
# To integrate into src/app/app.nim:
#   - Import src/ui/dialog.
#   - Create dialogs with newDialog/newConfirmDialog/newSaveDialog and pass app.font.
#   - Before dispatching events to widgets, pass Event to dialogManager.handleInput(event).
#   - Render dialogs after widgets: dialogManager.render().
#   - Check dialogManager.isModalActive to skip widget input when a modal is open.

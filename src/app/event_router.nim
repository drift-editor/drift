## Event routing through the node tree + command registry

import uirelays/input
import ../ui/node
import commands

type
  GlobalInput* = ref object
    lastEvent*: Event
    mouseX*, mouseY*: int
    consumed*: bool

proc consume*(gi: GlobalInput): bool =
  if gi.consumed: return false
  gi.consumed = true
  return true

proc isConsumed*(gi: GlobalInput): bool = gi.consumed

proc dispatchMouse*(gi: GlobalInput, root: Node, kind: MouseEventKind): bool =
  if gi == nil or root == nil: return false
  if gi.consumed: return false
  let target = hitTest(root, gi.mouseX, gi.mouseY)
  let handled = bubbleMouse(target, gi.lastEvent, kind)
  if handled:
    gi.consumed = true
  handled

proc dispatchKeyboard*(gi: GlobalInput, root: Node, commands: CommandRegistry): bool =
  if gi == nil or root == nil or commands == nil: return false
  if gi.consumed or gi.lastEvent.kind != KeyDownEvent:
    return false
  # 1. Focused node
  let focused = findFocused(root)
  if focused != nil and focused.onKeyDown != nil and focused.onKeyDown(focused, gi.lastEvent):
    gi.consumed = true
    return true
  # 2. Global commands
  if commands.dispatch(gi.lastEvent):
    gi.consumed = true
    return true
  false

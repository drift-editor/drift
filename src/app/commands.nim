## Command registry for keybindings and reusable actions

import std/tables
import uirelays/input

type
  CommandRegistry* = ref object
    actions*: Table[string, proc()]
    keybindings*: Table[(set[Modifier], KeyCode), string]

proc newCommandRegistry*(): CommandRegistry =
  CommandRegistry(
    actions: initTable[string, proc()](),
    keybindings: initTable[(set[Modifier], KeyCode), string]()
  )

proc register*(reg: CommandRegistry, id: string, action: proc()) =
  reg.actions[id] = action

proc bindKey*(reg: CommandRegistry, mods: set[Modifier], key: KeyCode, id: string) =
  reg.keybindings[(mods, key)] = id

proc exec*(reg: CommandRegistry, id: string) =
  if id in reg.actions:
    reg.actions[id]()

proc normalizeMods(mods: set[Modifier]): set[Modifier] =
  result = mods
  if GuiPressed in mods and CtrlPressed notin mods:
    result.excl GuiPressed
    result.incl CtrlPressed

proc dispatch*(reg: CommandRegistry, e: Event): bool =
  if e.kind != KeyDownEvent:
    return false
  var id = reg.keybindings.getOrDefault((e.mods, e.key), "")
  if id.len == 0:
    id = reg.keybindings.getOrDefault((normalizeMods(e.mods), e.key), "")
  if id.len > 0 and id in reg.actions:
    reg.actions[id]()
    return true
  false

proc hasCommand*(reg: CommandRegistry, id: string): bool =
  id in reg.actions

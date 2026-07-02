## User-configurable keybindings for Drift.
##
## Reads ~/.config/drift/keybindings.toml (simple key = "value" format)
## and returns a table of command-id -> (mods, key) overrides.
## The caller applies overrides by calling app.commands.bindKey() after
## initCommands(), which naturally replaces the default binding.
##
## File format example:
##   "file.save"       = "Ctrl+S"
##   "edit.deleteLine" = "Ctrl+Shift+K"
##   # This is a comment

import std/[os, strutils, tables]
import uirelays/input

proc keybindingsPath*(): string =
  getConfigDir() / "drift" / "keybindings.toml"

# ---------------------------------------------------------------------------
# Key name -> KeyCode lookup
# ---------------------------------------------------------------------------

const keyNames = {
  "a": KeyA, "b": KeyB, "c": KeyC, "d": KeyD, "e": KeyE,
  "f": KeyF, "g": KeyG, "h": KeyH, "i": KeyI, "j": KeyJ,
  "k": KeyK, "l": KeyL, "m": KeyM, "n": KeyN, "o": KeyO,
  "p": KeyP, "q": KeyQ, "r": KeyR, "s": KeyS, "t": KeyT,
  "u": KeyU, "v": KeyV, "w": KeyW, "x": KeyX, "y": KeyY,
  "z": KeyZ,
  "0": Key0, "1": Key1, "2": Key2, "3": Key3, "4": Key4,
  "5": Key5, "6": Key6, "7": Key7, "8": Key8, "9": Key9,
  "f1":  KeyF1,  "f2":  KeyF2,  "f3":  KeyF3,  "f4":  KeyF4,
  "f5":  KeyF5,  "f6":  KeyF6,  "f7":  KeyF7,  "f8":  KeyF8,
  "f9":  KeyF9,  "f10": KeyF10, "f11": KeyF11, "f12": KeyF12,
  "enter": KeyEnter, "return": KeyEnter,
  "space": KeySpace,
  "esc": KeyEsc, "escape": KeyEsc,
  "tab": KeyTab,
  "backspace": KeyBackspace,
  "delete": KeyDelete, "del": KeyDelete,
  "insert": KeyInsert,
  "left": KeyLeft, "right": KeyRight, "up": KeyUp, "down": KeyDown,
  "pageup": KeyPageUp, "pagedown": KeyPageDown,
  "home": KeyHome, "end": KeyEnd,
  "capslock": KeyCapslock,
  "comma": KeyComma, ",": KeyComma,
  "period": KeyPeriod, ".": KeyPeriod,
  "slash": KeySlash, "/": KeySlash,
}.toTable()

# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

proc parseKeyString*(s: string): tuple[mods: set[Modifier], key: KeyCode, ok: bool] =
  ## Parse a string like "Ctrl+Shift+K" into (mods, key, ok).
  ## Returns ok=false if any token is unrecognised.
  result.mods = {}
  result.key = KeyNone
  result.ok = false

  let parts = s.split('+')
  for part in parts:
    let p = part.strip().toLowerAscii()
    case p
    of "ctrl", "control", "cmd", "command", "gui":
      result.mods.incl(CtrlPressed)
    of "shift":
      result.mods.incl(ShiftPressed)
    of "alt", "option":
      result.mods.incl(AltPressed)
    else:
      if p in keyNames:
        result.key = keyNames[p]
      else:
        return   # unknown token — leave ok=false

  if result.key != KeyNone:
    result.ok = true

proc loadKeybindings*(path: string): Table[string, tuple[mods: set[Modifier], key: KeyCode]] =
  ## Load keybinding overrides from a TOML-style file.
  ## Each non-comment line must be:  "command.id" = "Mod+Key"
  result = initTable[string, tuple[mods: set[Modifier], key: KeyCode]]()
  if not fileExists(path): return
  try:
    for rawLine in lines(path):
      let line = rawLine.strip()
      if line.len == 0 or line.startsWith("#"): continue
      let eq = line.find('=')
      if eq < 0: continue
      var lhs = line[0 ..< eq].strip()
      var rhs = line[eq + 1 .. ^1].strip()
      # Strip surrounding quotes
      if lhs.len >= 2 and lhs[0] == '"' and lhs[^1] == '"':
        lhs = lhs[1 .. ^2]
      if rhs.len >= 2 and rhs[0] == '"' and rhs[^1] == '"':
        rhs = rhs[1 .. ^2]
      if lhs.len == 0 or rhs.len == 0: continue
      let parsed = parseKeyString(rhs)
      if parsed.ok:
        result[lhs] = (parsed.mods, parsed.key)
      else:
        stderr.writeLine("[keybindings] unrecognised key string: " & rhs & " for command: " & lhs)
  except CatchableError as e:
    stderr.writeLine("[keybindings] failed to load " & path & ": " & e.msg)

proc ensureDefaultKeybindingsFile*(path: string) =
  ## Create a commented reference file if it doesn't exist yet.
  if fileExists(path): return
  try:
    createDir(path.parentDir)
    writeFile(path, """# Drift keybindings override file
# Uncomment and edit any line to override the default binding.
# Format:  "command.id" = "Mod+Key"
# Modifiers: Ctrl (or Cmd on macOS), Shift, Alt
#
# "file.new"                    = "Ctrl+N"
# "file.open"                   = "Ctrl+O"
# "folder.open"                 = "Ctrl+Shift+O"
# "file.save"                   = "Ctrl+S"
# "file.saveAs"                 = "Ctrl+Shift+S"
# "file.close"                  = "Ctrl+W"
# "edit.undo"                   = "Ctrl+Z"
# "edit.redo"                   = "Ctrl+Shift+Z"
# "edit.deleteLine"             = "Ctrl+Shift+K"
# "edit.duplicateLine"          = "Ctrl+Shift+D"
# "edit.moveLineUp"             = "Alt+Up"
# "edit.moveLineDown"           = "Alt+Down"
# "edit.toggleComment"          = "Ctrl+Slash"
# "search.find"                 = "Ctrl+F"
# "search.replace"              = "Ctrl+H"
# "view.toggleSidebar"          = "Ctrl+B"
# "view.toggleTerminal"         = "Ctrl+T"
# "view.toggleGit"              = "Ctrl+Shift+G"
# "workbench.showCommands"      = "Ctrl+Shift+P"
# "workbench.quickOpen"         = "Ctrl+P"
# "navigate.gotoLine"           = "Ctrl+G"
# "debug.start"                 = "F5"
# "debug.stop"                  = "Shift+F5"
# "debug.stepOver"              = "F10"
# "debug.stepInto"              = "F11"
# "debug.stepOut"               = "Shift+F11"
# "debug.toggleBreakpoint"      = "F9"
""")
  except CatchableError as e:
    stderr.writeLine("[keybindings] failed to create default file: " & e.msg)

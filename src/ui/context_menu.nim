## Context Menu Component
## Right-click context menus for uirelays

import uirelays
import uirelays/screen
import uirelays/input
import theme, icons

const
  ItemHeight = 28
  MenuPadding = 4
  MinWidth = 120
  IconWidth = 24
  ShortcutPadding = 20

type
  MenuItemType* = enum
    mitNormal
    mitSeparator
    mitCheckbox
    mitSubmenu

  MenuItem* = ref object
    id*: string
    label*: string
    menuType*: MenuItemType
    shortcut*: string
    icon*: string
    isEnabled*: bool
    isChecked*: bool
    action*: proc()
    submenu*: ContextMenu

  ContextMenu* = ref object
    items*: seq[MenuItem]
    bounds*: Rect
    parent*: ContextMenu
    isVisible*: bool
    selectedIndex*: int
    font*: Font
    onClose*: proc()

# Menu Creation

proc newContextMenu*(font: Font): ContextMenu =
  ContextMenu(
    items: @[],
    bounds: rect(0, 0, MinWidth, 0),
    parent: nil,
    isVisible: false,
    selectedIndex: -1,
    font: font,
    onClose: nil
  )

proc newMenuItem*(id, label: string, action: proc() = nil): MenuItem =
  MenuItem(
    id: id,
    label: label,
    menuType: mitNormal,
    shortcut: "",
    icon: "",
    isEnabled: true,
    isChecked: false,
    action: action,
    submenu: nil
  )

proc newSeparator*(): MenuItem =
  MenuItem(
    id: "",
    label: "",
    menuType: mitSeparator,
    isEnabled: false
  )

proc newCheckboxItem*(id, label: string, checked: bool = false, action: proc() = nil): MenuItem =
  MenuItem(
    id: id,
    label: label,
    menuType: mitCheckbox,
    isEnabled: true,
    isChecked: checked,
    action: action
  )

proc newSubmenu*(id, label: string, submenu: ContextMenu): MenuItem =
  submenu.parent = nil
  MenuItem(
    id: id,
    label: label,
    menuType: mitSubmenu,
    isEnabled: true,
    submenu: submenu
  )

# Menu Building

proc addItem*(menu: ContextMenu, item: MenuItem) =
  if item.menuType == mitSubmenu and item.submenu != nil:
    item.submenu.parent = menu
  menu.items.add(item)

proc addItem*(menu: ContextMenu, id, label: string, action: proc() = nil) =
  menu.addItem(newMenuItem(id, label, action))

proc addSeparator*(menu: ContextMenu) =
  menu.addItem(newSeparator())

proc addCheckbox*(menu: ContextMenu, id, label: string, checked: bool = false, action: proc() = nil) =
  menu.addItem(newCheckboxItem(id, label, checked, action))

proc clear*(menu: ContextMenu) =
  menu.items = @[]

# Visibility Control

proc hide*(menu: ContextMenu)

proc hideAll*(menu: ContextMenu) =
  var current = menu
  while current != nil:
    current.hide()
    current = current.parent

proc fitMenuBounds*(x, y, w, h, screenW, screenH: int): Rect =
  var nx = x
  var ny = y
  if nx + w > screenW:
    nx = x - w
  if ny + h > screenH:
    ny = y - h
  if nx < 0:
    nx = 0
  if ny < 0:
    ny = 0
  rect(nx, ny, w, h)

proc showAt*(menu: ContextMenu, x, y: int) =
  menu.isVisible = true
  menu.selectedIndex = -1

  var height = MenuPadding * 2
  for item in menu.items:
    if item.menuType == mitSeparator:
      height += 8
    else:
      height += ItemHeight

  var maxWidth = MinWidth
  for item in menu.items:
    var itemWidth = item.label.len * 8 + IconWidth + ShortcutPadding
    if item.shortcut.len > 0:
      itemWidth += item.shortcut.len * 7 + ShortcutPadding
    maxWidth = max(maxWidth, itemWidth)

  menu.bounds = rect(x, y, maxWidth, height)

proc showAt*(menu: ContextMenu, x, y, screenW, screenH: int) =
  menu.showAt(x, y)
  menu.bounds = fitMenuBounds(menu.bounds.x, menu.bounds.y,
                              menu.bounds.w, menu.bounds.h,
                              screenW, screenH)

proc hide*(menu: ContextMenu) =
  menu.isVisible = false
  menu.selectedIndex = -1
  for item in menu.items:
    if item.submenu != nil:
      item.submenu.hide()
  if menu.onClose != nil:
    menu.onClose()

# Input Handling

proc handleInput*(menu: ContextMenu, event: Event): bool =
  if not menu.isVisible:
    return false

  case event.kind
  of KeyDownEvent:
    case event.key
    of KeyEsc:
      menu.hide()
      return true
    of KeyUp:
      if menu.selectedIndex > 0:
        menu.selectedIndex -= 1
        while menu.selectedIndex > 0 and menu.items[menu.selectedIndex].menuType == mitSeparator:
          menu.selectedIndex -= 1
      return true
    of KeyDown:
      if menu.selectedIndex < menu.items.len - 1:
        menu.selectedIndex += 1
        while menu.selectedIndex < menu.items.len - 1 and menu.items[menu.selectedIndex].menuType == mitSeparator:
          menu.selectedIndex += 1
      return true
    of KeyEnter:
      if menu.selectedIndex >= 0 and menu.selectedIndex < menu.items.len:
        let item = menu.items[menu.selectedIndex]
        if item.isEnabled:
          case item.menuType
          of mitNormal, mitCheckbox:
            if item.menuType == mitCheckbox:
              item.isChecked = not item.isChecked
            if item.action != nil:
              item.action()
            menu.hideAll()
          of mitSubmenu:
            if item.submenu != nil:
              var itemY = menu.bounds.y + MenuPadding
              for i in 0 ..< menu.selectedIndex:
                if menu.items[i].menuType == mitSeparator:
                  itemY += 8
                else:
                  itemY += ItemHeight
              item.submenu.showAt(menu.bounds.x + menu.bounds.w, itemY)
          of mitSeparator:
            discard
      return true
    else:
      return false

  of MouseMoveEvent:
    # Update hover highlight based on mouse position
    if event.x < menu.bounds.x or event.x >= menu.bounds.x + menu.bounds.w or
       event.y < menu.bounds.y or event.y >= menu.bounds.y + menu.bounds.h:
      menu.selectedIndex = -1
      return false

    let relativeY = event.y - menu.bounds.y - MenuPadding
    var y = 0
    var index = -1
    for i, item in menu.items:
      let h = if item.menuType == mitSeparator: 8 else: ItemHeight
      if relativeY >= y and relativeY < y + h:
        index = i
        break
      y += h

    if index >= 0 and index < menu.items.len:
      let item = menu.items[index]
      if item.isEnabled and item.menuType != mitSeparator:
        menu.selectedIndex = index
      else:
        menu.selectedIndex = -1
    else:
      menu.selectedIndex = -1

    return true

  of MouseDownEvent:
    # Check if mouse is in menu bounds
    if event.x < menu.bounds.x or event.x >= menu.bounds.x + menu.bounds.w or
       event.y < menu.bounds.y or event.y >= menu.bounds.y + menu.bounds.h:
      # Click outside closes menu (unless clicking a submenu)
      for item in menu.items:
        if item.menuType == mitSubmenu and item.submenu != nil and item.submenu.isVisible:
          if event.x >= item.submenu.bounds.x and event.x < item.submenu.bounds.x + item.submenu.bounds.w and
             event.y >= item.submenu.bounds.y and event.y < item.submenu.bounds.y + item.submenu.bounds.h:
            return item.submenu.handleInput(event)
      menu.hide()
      return true

    # Handle mouse click for selection
    let relativeY = event.y - menu.bounds.y - MenuPadding
    var y = 0
    var index = -1
    for i, item in menu.items:
      let h = if item.menuType == mitSeparator: 8 else: ItemHeight
      if relativeY >= y and relativeY < y + h:
        index = i
        break
      y += h

    if index >= 0 and index < menu.items.len:
      menu.selectedIndex = index
      let item = menu.items[index]
      if item.isEnabled:
        case item.menuType
        of mitNormal, mitCheckbox:
          if item.menuType == mitCheckbox:
            item.isChecked = not item.isChecked
          if item.action != nil:
            item.action()
          menu.hideAll()
        of mitSubmenu:
          if item.submenu != nil:
            item.submenu.showAt(menu.bounds.x + menu.bounds.w, menu.bounds.y + MenuPadding + y)
        of mitSeparator:
          discard

    return true

  else:
    discard

  false

# Rendering

proc render*(menu: ContextMenu) =
  if not menu.isVisible:
    return

  # Background
  fillRect(menu.bounds, currentTheme.getColor(tcSurface))

  # Border
  let b = menu.bounds
  fillRect(rect(b.x,     b.y,      b.w, 1), currentTheme.getColor(tcBorder))
  fillRect(rect(b.x,     b.y + b.h - 1, b.w, 1), currentTheme.getColor(tcBorder))
  fillRect(rect(b.x,     b.y,      1, b.h), currentTheme.getColor(tcBorder))
  fillRect(rect(b.x + b.w - 1, b.y, 1, b.h), currentTheme.getColor(tcBorder))

  # Shadow (simple offset rect)
  fillRect(rect(b.x + 4, b.y + 4, b.w, b.h), color(0, 0, 0, 50))

  var y = b.y + MenuPadding

  for i, item in menu.items:
    let itemBounds = rect(b.x + MenuPadding, y, b.w - MenuPadding * 2, ItemHeight)

    # Selection highlight
    if i == menu.selectedIndex and item.menuType != mitSeparator and item.isEnabled:
      fillRect(itemBounds, currentTheme.getColor(tcSelection))

    case item.menuType
    of mitSeparator:
      fillRect(rect(b.x + MenuPadding * 2, y + 3, b.w - MenuPadding * 4, 1),
               currentTheme.getColor(tcBorder))
      y += 8

    of mitNormal, mitCheckbox, mitSubmenu:
      let textColor = if item.isEnabled: currentTheme.getColor(tcText)
                      else: currentTheme.getColor(tcTextDisabled)

      # Checkbox
      if item.menuType == mitCheckbox:
        if item.isChecked:
          drawIcon(iiCheck, itemBounds.x + 4, y + 4)

      # Icon
      elif item.icon.len > 0:
        discard drawText(menu.font, itemBounds.x + 4, y + 4, item.icon, textColor,
                         color(0, 0, 0, 0))

      # Label
      let labelX = if item.menuType == mitCheckbox: itemBounds.x + 24 else: itemBounds.x + 4
      discard drawText(menu.font, labelX, y + 5, item.label, textColor,
                       color(0, 0, 0, 0))

      # Shortcut
      if item.shortcut.len > 0:
        let shortcutWidth = item.shortcut.len * 7
        discard drawText(menu.font,
                         itemBounds.x + itemBounds.w - shortcutWidth - 8,
                         y + 5,
                         item.shortcut,
                         currentTheme.getColor(tcTextSecondary),
                         color(0, 0, 0, 0))

      # Submenu arrow
      if item.menuType == mitSubmenu:
        discard drawText(menu.font,
                         itemBounds.x + itemBounds.w - 16,
                         y + 5,
                         "▶",
                         textColor,
                         color(0, 0, 0, 0))

      y += ItemHeight

  # Render submenu
  for item in menu.items:
    if item.menuType == mitSubmenu and item.submenu != nil:
      item.submenu.render()

# Common Menu Builders

proc buildEditorContextMenu*(font: Font, cut, copy, paste, selectAll: proc()): ContextMenu =
  let menu = newContextMenu(font)
  menu.addItem("cut", "Cut", cut)
  menu.addItem("copy", "Copy", copy)
  menu.addItem("paste", "Paste", paste)
  menu.addSeparator()
  menu.addItem("selectAll", "Select All", selectAll)
  menu

proc buildTabContextMenu*(font: Font, close, closeOthers, closeAll, closeRight: proc()): ContextMenu =
  let menu = newContextMenu(font)
  menu.addItem("close", "Close", close)
  menu.addItem("closeOthers", "Close Others", closeOthers)
  menu.addItem("closeRight", "Close to the Right", closeRight)
  menu.addSeparator()
  menu.addItem("closeAll", "Close All", closeAll)
  menu

# INTEGRATION_NOTES
# This module is a port of src_old_backup/ui/components/context_menu.nim to uirelays.
# Changes made:
#   - Uses uirelays/screen.Rect (x,y,w,h as int) instead of float32-based Rect.
#   - Uses uirelays/screen.Color (uint8 r,g,b,a).
#   - Rendering uses global fillRect and drawText (with Font + fg/bg colors).
#   - handleInput uses uirelays/input.Event instead of the old InputEvent type.
#   - showAt takes separate x,y int parameters instead of a Vec2.
#   - Removed drawRectOutline; borders are drawn manually with fillRect.
#   - hideAll was moved before showAt to resolve forward-reference requirement.
# To integrate into src/app/app.nim:
#   - Import src/ui/context_menu.
#   - Create menu with newContextMenu(app.font).
#   - On right-click (or relevant trigger), call menu.showAt(e.x, e.y).
#   - Pass events to menu.handleInput(event) before widget input.
#   - Render menu after widgets: menu.render().

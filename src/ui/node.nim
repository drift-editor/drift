## Lightweight node tree for event routing in uirelays
## Render stays immediate-mode; only input routes through the tree.

import std/[strutils, algorithm]
import uirelays
import uirelays/input

type
  MouseEventKind* = enum
    mkDown
    mkMove
    mkWheel
    mkUp

  Node* = ref object
    id*: string
    bounds*: Rect
    zIndex*: int
    visible*: bool
    focus*: bool
    children*: seq[Node]
    parent*: Node
    hasCursor*: bool
    cursor*: CursorKind
    cursorResolver*: proc(n: Node, x, y: int): CursorKind
    onMouseDown*: proc(n: Node, e: Event): bool
    onMouseMove*: proc(n: Node, e: Event): bool
    onMouseUp*: proc(n: Node, e: Event): bool
    onMouseWheel*: proc(n: Node, e: Event): bool
    onKeyDown*: proc(n: Node, e: Event): bool

proc newNode*(id: string): Node =
  Node(id: id, visible: true, zIndex: 0, focus: false, hasCursor: false, cursor: curDefault)

proc setCursorStyle*(node: Node, cursor: CursorKind) =
  node.hasCursor = true
  node.cursor = cursor
  node.cursorResolver = nil

proc setCursorResolver*(node: Node, resolver: proc(n: Node, x, y: int): CursorKind) =
  node.hasCursor = true
  node.cursorResolver = resolver

proc addChild*(parent, child: Node) =
  child.parent = parent
  parent.children.add(child)

proc hitTest*(root: Node, x, y: int): Node =
  if not root.visible or not root.bounds.contains(point(x, y)):
    return nil
  # Front-to-back within children: sort by descending zIndex for hit-test
  var sorted = root.children
  sorted.sort(proc(a, b: Node): int = cmp(b.zIndex, a.zIndex))
  for child in sorted:
    let hit = hitTest(child, x, y)
    if hit != nil:
      return hit
  return root

proc bubbleMouse*(target: Node, e: Event, kind: MouseEventKind): bool =
  if target == nil:
    return false
  var chain: seq[Node]
  var n = target
  while n != nil:
    chain.add(n)
    n = n.parent

  for i in countdown(chain.high, 0):
    let node = chain[i]
    let consumed = case kind
      of mkDown:
        if node.onMouseDown != nil: node.onMouseDown(node, e) else: false
      of mkMove:
        if node.onMouseMove != nil: node.onMouseMove(node, e) else: false
      of mkUp:
        if node.onMouseUp != nil: node.onMouseUp(node, e) else: false
      of mkWheel:
        if node.onMouseWheel != nil: node.onMouseWheel(node, e) else: false
    if consumed:
      return true
  false

proc findFocused*(root: Node): Node =
  if not root.visible:
    return nil
  if root.focus:
    return root
  for child in root.children:
    let f = findFocused(child)
    if f != nil:
      return f
  nil

proc dump*(root: Node, indent: int = 0) =
  let prefix = spaces(indent * 2)
  stderr.writeLine(prefix & root.id & " z=" & $root.zIndex & " visible=" & $root.visible & " bounds=" & $root.bounds)
  for child in root.children:
    dump(child, indent + 1)

## Cursor resolution using the node tree
##
## Each Node can optionally own cursor resolution. We hit-test to the front-most
## node under the pointer, then walk up ancestors until we find an explicit
## cursor owner. This keeps overlay behavior intuitive and avoids stale cursor
## state when no mouse move is dispatched to a specific widget.

import uirelays/screen
import ../ui/node

proc resolveCursor*(target: Node, mouseX, mouseY: int): CursorKind =
  if target == nil:
    return curDefault

  var node = hitTest(target, mouseX, mouseY)
  while node != nil:
    if node.hasCursor:
      if node.cursorResolver != nil:
        return node.cursorResolver(node, mouseX, mouseY)
      return node.cursor
    node = node.parent

  curDefault

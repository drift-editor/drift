import ../src/editor/diff_engine

let oldText = """line one
line two
line three
line four"""

let newText = """line one
line two modified
line three
new inserted line
line four"""

let ops = diffText(oldText, newText)
for op in ops:
  case op.kind
  of dokEqual: echo "= ", op.oldLine, ": ", op.oldText
  of dokDelete: echo "- ", op.oldLine, ": ", op.oldText
  of dokInsert: echo "+ ", op.newLine, ": ", op.newText
  of dokReplace: echo "~ ", op.oldLine, "->", op.newLine, ": ", op.oldText, " | ", op.newText

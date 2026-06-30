## Tests for file operation detection in the built-in AI agent.
import ../src/services/ai_thread
import ../src/core/config

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# --- detectFileOp: delete commands ---
var op = detectFileOp("remove docs/superpowers")
assertEq(op.kind.int, fokDelete.int, "remove -> delete")
assertEq(op.path, "docs/superpowers", "remove path")

op = detectFileOp("delete src/main.nim")
assertEq(op.kind.int, fokDelete.int, "delete -> delete")
assertEq(op.path, "src/main.nim", "delete path")

op = detectFileOp("rm temp.log")
assertEq(op.kind.int, fokDelete.int, "rm -> delete")
assertEq(op.path, "temp.log", "rm path")

op = detectFileOp("del old_backup")
assertEq(op.kind.int, fokDelete.int, "del -> delete")
assertEq(op.path, "old_backup", "del path")

# --- detectFileOp: articles and suffixes ---
op = detectFileOp("remove the docs/superpowers directory")
assertEq(op.kind.int, fokDelete.int, "remove the ... directory -> delete")
assertEq(op.path, "docs/superpowers", "article+suffix stripped")

op = detectFileOp("delete the config folder")
assertEq(op.kind.int, fokDelete.int, "delete the ... folder -> delete")
assertEq(op.path, "config", "article+folder stripped")

# --- detectFileOp: quoted paths ---
op = detectFileOp("remove \"my file.txt\"")
assertEq(op.kind.int, fokDelete.int, "quoted remove -> delete")
assertEq(op.path, "my file.txt", "quotes stripped from path")

# --- detectFileOp: create commands ---
op = detectFileOp("create file src/new.nim")
assertEq(op.kind.int, fokCreate.int, "create file -> create")
assertEq(op.path, "src/new.nim", "create path")

op = detectFileOp("new file test.txt")
assertEq(op.kind.int, fokCreate.int, "new file -> create")
assertEq(op.path, "test.txt", "new file path")

op = detectFileOp("touch notes.md")
assertEq(op.kind.int, fokCreate.int, "touch -> create")
assertEq(op.path, "notes.md", "touch path")

# --- detectFileOp: move/rename commands ---
op = detectFileOp("move old.txt to new.txt")
assertEq(op.kind.int, fokMove.int, "move -> move")
assertEq(op.path, "old.txt", "move src")
assertEq(op.destPath, "new.txt", "move dst")

op = detectFileOp("rename src/a.nim to src/b.nim")
assertEq(op.kind.int, fokMove.int, "rename -> move")
assertEq(op.path, "src/a.nim", "rename src")
assertEq(op.destPath, "src/b.nim", "rename dst")

# --- detectFileOp: non-commands return fokNone ---
op = detectFileOp("What is the best way to remove duplicates from a list?")
assertEq(op.kind.int, fokNone.int, "question about removing -> none")

op = detectFileOp("How do I delete a git branch?")
assertEq(op.kind.int, fokNone.int, "question about deleting -> none")

op = detectFileOp("Explain how to create a web server")
assertEq(op.kind.int, fokNone.int, "question about creating -> none")

op = detectFileOp("Hello, how are you?")
assertEq(op.kind.int, fokNone.int, "greeting -> none")

op = detectFileOp("")
assertEq(op.kind.int, fokNone.int, "empty -> none")

# --- detectFileOp: multi-word path without slash is rejected for delete ---
# "remove my old notes" has spaces and no slash -> ambiguous, falls through
op = detectFileOp("remove my old notes")
assertEq(op.kind.int, fokNone.int, "ambiguous multi-word no slash -> none")

echo "All file operation detection tests passed!"
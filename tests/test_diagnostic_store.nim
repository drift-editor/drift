import std/tables
import ../src/ui/diagnostics_panel

# --- update: replace entries for a URI ---
var store: DiagnosticStore

let e1 = DiagnosticEntry(uri: "file:///a.nim", severity: SeverityError,   message: "err",  source: "nim", line: 0, col: 0)
let e2 = DiagnosticEntry(uri: "file:///a.nim", severity: SeverityWarning, message: "warn", source: "nim", line: 1, col: 0)
let e3 = DiagnosticEntry(uri: "file:///b.nim", severity: SeverityError,   message: "err2", source: "nim", line: 5, col: 3)

# 1.1 / 1.2 — store retains entries and replaces on update
store.update("file:///a.nim", @[e1, e2])
assert store.data.hasKey("file:///a.nim"), "URI should be present after update"
assert store.data["file:///a.nim"].len == 2, "Should have 2 entries"

store.update("file:///a.nim", @[e1])
assert store.data["file:///a.nim"].len == 1, "Replace should leave 1 entry"

# 1.3 — empty entries removes the URI key
store.update("file:///a.nim", @[])
assert not store.data.hasKey("file:///a.nim"), "URI should be removed when entries is empty"

# 1.4 — errorCount across all URIs
store.update("file:///a.nim", @[e1, e2])
store.update("file:///b.nim", @[e3])
assert store.errorCount() == 2, "Expected 2 errors, got " & $store.errorCount()

# 1.5 — warningCount across all URIs
assert store.warningCount() == 1, "Expected 1 warning, got " & $store.warningCount()

# Zero counts when store is empty
var empty: DiagnosticStore
assert empty.errorCount() == 0
assert empty.warningCount() == 0

echo "All DiagnosticStore tests passed."

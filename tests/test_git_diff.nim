import ../src/editor/git_diff

# Test parseHunkHeader indirectly via getDiffLines
# We'll create a temp file, init git if needed, modify it, and check output
import std/[os, osproc, strutils]

let tmpDir = getTempDir() / "drift_git_diff_test"
removeDir(tmpDir)
createDir(tmpDir)

# Init git repo
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git init -q")
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git config user.email 'test@test.com'")
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git config user.name 'Test'")

# Create initial file
let testFile = tmpDir / "test.nim"
writeFile(testFile, "line1\nline2\nline3\nline4\nline5\n")
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git add test.nim && git commit -q -m 'initial'")

# Modify line 3
writeFile(testFile, "line1\nline2\nmodified3\nline4\nline5\n")
var diff = getDiffLines(testFile)
echo "Modified line 3: ", diff
assert diff.len == 1 and diff[0].line == 2 and diff[0].kind == 'M', "Expected modification at line 2"

# Add line after 1
writeFile(testFile, "line1\nnew1.5\nline2\nmodified3\nline4\nline5\n")
diff = getDiffLines(testFile)
echo "Added + modified: ", diff
# Should have addition at line 1 and modification at line 3
assert diff.len == 2, "Expected 2 changes"

# Delete line 2
writeFile(testFile, "line1\nmodified3\nline4\nline5\n")
diff = getDiffLines(testFile)
echo "Deleted line 2 + modified line 3: ", diff
# Should have modification at line 1 (since line2 was deleted, modified3 moved up)
# Wait, if we delete line2 and keep modified3, that's:
# working tree: line1, modified3, line4, line5
# HEAD: line1, line2, line3, line4, line5
# diff: -line2, -line3, +modified3
# So line3 (0-indexed line 2) is modified? Actually:
# -line2 is at old line 2, -line3 at old line 3, +modified3 at new line 2
# The parser should see: - at old 2, - at old 3, + at new 2
# Since there are 2 pending deletions and 1 addition, the + consumes 1 deletion -> modified at new line 2
# And there's 1 remaining deletion at old line 3 -> 'D' at line 3
assert diff.len >= 1, "Expected at least 1 change"

# Reset to a clean state and test hunk parsing helpers.
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git checkout -- test.nim")
writeFile(testFile, "line1\nline2\nmodified3\nline4\nline5\n")
let hunks = parseDiffHunks(testFile)
echo "Hunks: ", hunks
assert hunks.len == 1, "Expected one hunk"
assert hunks[0].newStart == 2 and hunks[0].newCount == 3, "Expected new range to cover lines 2-4 with context"
assert findHunkAtLine(hunks, 0) == -1, "Line 0 should not be in a hunk"
assert findHunkAtLine(hunks, 1) == 0, "Line 1 (0-based) is context inside the hunk"
assert findHunkAtLine(hunks, 2) == 0, "Line 2 (0-based) is the modified line"
assert findHunkAtLine(hunks, 3) == 0, "Line 3 (0-based) is context inside the hunk"
assert findHunkAtLine(hunks, 4) == -1, "Line 4 should not be in a hunk"
assert hunkOldText(hunks[0]) == "line2\nline3\nline4", "Old hunk text should include context"
assert hunkNewText(hunks[0]) == "line2\nmodified3\nline4", "New hunk text should include context"

# Test staged hunks.
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git add test.nim")
let stagedHunks = parseDiffHunks(testFile, staged = true)
echo "Staged hunks: ", stagedHunks
assert stagedHunks.len == 1, "Expected one staged hunk"
assert hunkNewText(stagedHunks[0]) == "line2\nmodified3\nline4", "Staged new text should include context"

# Test multiple hunks by creating spaced-out changes.
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git checkout -- test.nim")
writeFile(testFile, "line1\nline2\nline3\nline4\nline5\n")
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git add test.nim && git commit -q -m 'clean'")
writeFile(testFile, "changed1\nline2\nline3\nline4\nchanged5\n")
let multi = parseDiffHunks(testFile)
echo "Multi hunks: ", multi
assert multi.len == 2, "Expected two hunks"
assert findHunkAtLine(multi, 0) == 0, "First hunk covers line 0"
assert findHunkAtLine(multi, 4) == 1, "Second hunk covers line 4"

# Test hunk deletion.
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git add test.nim && git commit -q -m 'two hunks'")
writeFile(testFile, "line2\nline3\nline4\nchanged5\n")
let delHunks = parseDiffHunks(testFile)
echo "Deletion hunks: ", delHunks
assert delHunks.len >= 1, "Expected at least one deletion hunk"
let delIdx = findHunkAtLine(delHunks, 0)
assert delIdx >= 0, "Should find a hunk covering the deletion context"
assert "changed1" in hunkOldText(delHunks[delIdx]).splitLines(), "Old text should include the deleted line"
assert "changed1" notin hunkNewText(delHunks[delIdx]).splitLines(), "New text should not include the deleted line"

# Test reverting a hunk.
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git checkout -- test.nim")
writeFile(testFile, "line1\nline2\nline3\nline4\nline5\n")
discard execShellCmd("cd " & tmpDir.quoteShell() & " && git add test.nim && git commit -q -m 'clean2' > /dev/null 2>&1")
writeFile(testFile, "changed1\nline2\nline3\nline4\nchanged5\n")
let revHunks = parseDiffHunks(testFile)
echo "Revert hunks: ", revHunks
assert revHunks.len >= 1, "Expected at least one hunk to revert"
assert revertHunk(testFile, revHunks[0]), "Expected revertHunk to succeed"
let reverted = readFile(testFile)
echo "Reverted file:\n", reverted
assert reverted == "line1\nline2\nline3\nline4\nchanged5\n", "First hunk should be reverted"

echo "All git diff tests passed!"

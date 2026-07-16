## Git actions: AI review, hunk copy/revert, branch menu.

proc reviewChanges*(app: App) =
  ## Lazy agentic review: send only file list + stats, let the agent explore files and diffs via tools.
  let repoRoot = if app.gitPanel.currentPath.len > 0: app.gitPanel.currentPath else: getCurrentDir()
  if not gitcmd.isGitRepository(repoRoot):
    discard app.notificationManager.warning("Not a git repository")
    return

  let allStatus = gitcmd.parseGitStatus(repoRoot)

  var fileList = ""
  for f in allStatus:
    var parts: seq[string]
    if f.stagedStatus != gitcmd.gfsUnmodified:
      parts.add("staged")
    if f.workingStatus != gitcmd.gfsUnmodified:
      if f.workingStatus == gitcmd.gfsUntracked:
        parts.add("new")
      else:
        parts.add("unstaged")
    fileList.add("- " & f.path & " (" & parts.join(", ") & ")\n")

  if fileList.len == 0:
    discard app.notificationManager.info("No local changes to review")
    return

  let branch = gitcmd.getCurrentBranch(repoRoot)

  var prompt = "You are conducting a code review of local git changes.\n\n"
  prompt.add("Repository: " & repoRoot & "\n")
  prompt.add("Branch: " & branch & "\n\n")
  prompt.add("Changed files:\n" & fileList & "\n")
  prompt.add("Use the following tools to explore files and diffs as needed:\n")
  prompt.add("- `fs/read_text_file` 鈥?read the full content of any file (pass absolute path as `\"path\"`)\n")
  prompt.add("- `git/get_file_diff` 鈥?get the diff for a specific file (pass absolute path as `\"path\"`)\n")
  prompt.add("- `git/get_diff` 鈥?get the full working tree diff (pass `\"repoRoot\": \"" & repoRoot & "\"`)\n\n")
  prompt.add("Please review thoroughly. Provide:\n")
  prompt.add("1. **Summary** 鈥?what changed at a high level\n")
  prompt.add("2. **Issues** 鈥?bugs, anti-patterns, or concerns (with line references)\n")
  prompt.add("3. **Suggestions** 鈥?specific improvements with reasoning\n")
  prompt.add("4. **Approval status** 鈥?Approve / Request changes / Needs discussion\n")

  app.aiPanelVisible = true
  if app.aiThread == nil:
    app.aiThread = newAIThread(app.config)
  app.aiThread.sendMessage(prompt)
  app.aiPanel.isStreaming = true
  if app.tooltip.visible: app.tooltip.hideTooltip()


proc copyOldHunk(app: App) =
  ## Copy the old-file text of the unstaged diff hunk at the cursor line.
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len: return
  let b = app.buffers[app.currentBuffer]
  if b.path.len == 0 or b.diffPath.len > 0: return
  let hunks = parseDiffHunks(b.path, staged = false)
  let idx = findHunkAtLine(hunks, b.ed.currentLine)
  if idx < 0:
    discard app.notificationManager.info("No unstaged hunk at the current line")
    return
  let text = hunkOldText(hunks[idx])
  if text.len == 0: return
  putClipboardText(text)
  app.pushClipboardHistory(text)


proc copyNewHunk(app: App) =
  ## Copy the new-file text of the unstaged diff hunk at the cursor line.
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len: return
  let b = app.buffers[app.currentBuffer]
  if b.path.len == 0 or b.diffPath.len > 0: return
  let hunks = parseDiffHunks(b.path, staged = false)
  let idx = findHunkAtLine(hunks, b.ed.currentLine)
  if idx < 0:
    discard app.notificationManager.info("No unstaged hunk at the current line")
    return
  let text = hunkNewText(hunks[idx])
  if text.len == 0: return
  putClipboardText(text)
  app.pushClipboardHistory(text)


proc revertCurrentHunk(app: App) =
  ## Revert the unstaged diff hunk at the cursor line.
  if app.currentBuffer < 0 or app.currentBuffer >= app.buffers.len: return
  let b = app.buffers[app.currentBuffer]
  if b.path.len == 0 or b.diffPath.len > 0: return
  if b.ed.changed:
    discard app.notificationManager.warning("Save the file before reverting a hunk")
    return
  let hunks = parseDiffHunks(b.path, staged = false)
  let idx = findHunkAtLine(hunks, b.ed.currentLine)
  if idx < 0:
    discard app.notificationManager.info("No unstaged hunk at the current line")
    return
  if revertHunk(b.path, hunks[idx]):
    app.buffers[app.currentBuffer].ed.loadFromFile(b.path)
    app.buffers[app.currentBuffer].lastChanged = false
    discard app.notificationManager.info("Reverted hunk")
  else:
    discard app.notificationManager.error("Failed to revert hunk")


proc showBranchMenu(app: App, bounds: coords.Rect) =
  app.branchMenu.items = @[]
  let branches = app.gitPanel.listBranches()
  let current = app.gitPanel.currentBranch
  if branches.len == 0:
    let item = newMenuItem("none", "No branches found", proc() = discard)
    item.isEnabled = false
    app.branchMenu.addItem(item)
  else:
    proc makeCheckoutProc(b: string): proc() =
      result = proc() =
        if app.gitPanel.checkoutBranch(b):
          app.gitPanel.updateRepository()
    for b in branches:
      if b == current:
        app.branchMenu.addItem(newCheckboxItem(b, b, true, makeCheckoutProc(b)))
      else:
        app.branchMenu.addItem(newMenuItem(b, b, makeCheckoutProc(b)))
  app.branchMenu.showAt(bounds.x, bounds.y)
  app.branchMenu.bounds.y -= app.branchMenu.bounds.h


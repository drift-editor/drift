import uirelays/screen
import ../src/ui/search_panel
import ../src/core/config

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# --- History deduplication and cap ---
var panel = newSearchPanel(Font(0), FontMetrics())

panel.pushSearchHistory("alpha")
assertEq(panel.searchHistory, @["alpha"], "first history entry")

panel.pushSearchHistory("beta")
assertEq(panel.searchHistory, @["alpha", "beta"], "second history entry")

panel.pushSearchHistory("alpha")
assertEq(panel.searchHistory, @["beta", "alpha"], "duplicate moves to end")

panel.pushSearchHistory("")
assertEq(panel.searchHistory, @["beta", "alpha"], "empty query not stored")

for i in 1..20:
  panel.pushSearchHistory("q" & $i)
assertEq(panel.searchHistory.len, 20, "history capped at 20")
assertEq(panel.searchHistory[0], "q1", "oldest entry evicted")
assertEq(panel.searchHistory[^1], "q20", "newest entry kept")

# --- Counter formatting ---
var counterPanel = newSearchPanel(Font(0), FontMetrics())
counterPanel.mode = smCurrentFile
counterPanel.matches = @[FileMatch(a: 0, b: 3), FileMatch(a: 5, b: 8)]
counterPanel.currentMatchIndex = 0
assertEq(counterPanel.formatSearchCounter(), "1/2", "file counter first match")

counterPanel.currentMatchIndex = 1
assertEq(counterPanel.formatSearchCounter(), "2/2", "file counter second match")

counterPanel.matches.setLen(0)
counterPanel.currentMatchIndex = -1
assertEq(counterPanel.formatSearchCounter(), "0/0", "file counter no matches")

counterPanel.mode = smWorkspace
counterPanel.workspaceMatches = @[WorkspaceMatch(path: "a", line: 0, col: 0, matchLen: 1, preview: "a")]
assertEq(counterPanel.formatSearchCounter(), "1 results", "workspace counter one result")

counterPanel.workspaceMatches.setLen(0)
assertEq(counterPanel.formatSearchCounter(), "0 results", "workspace counter no results")

counterPanel.errorText = "No workspace open"
assertEq(counterPanel.formatSearchCounter(), "No workspace open", "error takes precedence")

# --- Config load/save round-trip ---
var cfg = defaultConfig()
cfg.searchCaseSensitive = true
cfg.searchUseRegex = true
cfg.searchWholeWord = true
cfg.searchHistory = @["old", "newer"]
cfg.searchRememberOptions = true

var cfgPanel = newSearchPanel(Font(0), FontMetrics())
loadSearchState(cfgPanel, cfg)
assertEq(cfgPanel.caseSensitive, true, "load case sensitive")
assertEq(cfgPanel.useRegex, true, "load use regex")
assertEq(cfgPanel.wholeWord, true, "load whole word")
assertEq(cfgPanel.searchHistory, @["old", "newer"], "load history")
assertEq(cfgPanel.findText, "newer", "load last history as initial query")

cfgPanel.findText = "updated"
cfgPanel.pushSearchHistory(cfgPanel.findText)
saveSearchState(cfgPanel, cfg)
assertEq(cfg.searchHistory[^1], "updated", "save writes history")
assertEq(cfg.searchCaseSensitive, true, "save writes case sensitive")

# --- History cycling does not add duplicates ---
var cyclePanel = newSearchPanel(Font(0), FontMetrics())
cyclePanel.searchHistory = @["one", "two", "three"]
cyclePanel.historyIndex = cyclePanel.searchHistory.high
cyclePanel.findText = "three"
# Simulating Alt+Up twice should move to "two" then "one" without changing history.
cyclePanel.cycleSearchHistory(nil, -1)
assertEq(cyclePanel.findText, "two", "alt-up moves to previous history")
assertEq(cyclePanel.searchHistory.len, 3, "history unchanged by cycling")
cyclePanel.cycleSearchHistory(nil, -1)
assertEq(cyclePanel.findText, "one", "alt-up moves to oldest history")
cyclePanel.cycleSearchHistory(nil, 1)
assertEq(cyclePanel.findText, "two", "alt-down moves to newer history")

echo "All search panel tests passed!"

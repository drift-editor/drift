import std/os
import ../src/core/search_history

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# Cleanup test file before loading
removeFile(getSearchHistoryPath())

# Empty history returns empty
let empty = loadSearchHistory()
assertEq(empty, @[], "empty history")

# Save and load round-trip
let hist = @["alpha", "beta", "gamma"]
saveSearchHistory(hist)
let loaded = loadSearchHistory()
assertEq(loaded, @["gamma", "beta", "alpha"], "round-trip newest first")

# Cap at MaxSearchHistory
var big: seq[string] = @[]
for i in 0 ..< 100:
  big.add("q" & $i)
saveSearchHistory(big)
let capped = loadSearchHistory()
assertEq(capped.len, 50, "capped at 50")
assertEq(capped[0], "q99", "latest first")
assertEq(capped[^1], "q50", "oldest evicted")

# Merge removes duplicates and keeps order
let a = @["one", "two", "three"]
let b = @["two", "four", "five"]
let merged = mergeSearchHistory(a, b)
assertEq(merged, @["two", "four", "five", "one", "three"], "merge dedup")

# Merge caps
var manyA: seq[string] = @[]
var manyB: seq[string] = @[]
for i in 0 ..< 30:
  manyA.add("a" & $i)
  manyB.add("b" & $i)
let mergedCap = mergeSearchHistory(manyA, manyB)
assertEq(mergedCap.len, 50, "merge capped")

# Cleanup test file
removeFile(getSearchHistoryPath())

echo "All search history tests passed!"

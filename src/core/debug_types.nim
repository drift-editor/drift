## Shared types and helpers for the run/debug feature.

import std/json

type
  DebugSessionState* = enum
    dssOff
    dssStarting
    dssReady
    dssRunning
    dssStopped
    dssError
    dssTerminated

  StackFrame* = object
    id*: int
    name*: string
    source*: string
    line*: int
    column*: int

  Breakpoint* = object
    path*: string
    line*: int
    enabled*: bool

proc toDAPLine*(line: int): int =
  ## Convert Drift's 0-based line numbers to DAP's 1-based line numbers.
  line + 1

proc fromDAPLine*(line: int): int =
  ## Convert DAP's 1-based line numbers to Drift's 0-based line numbers.
  line - 1

proc statusString*(state: DebugSessionState): string =
  case state
  of dssOff: "Not started"
  of dssStarting: "Starting"
  of dssReady: "Ready"
  of dssRunning: "Running"
  of dssStopped: "Stopped"
  of dssError: "Error"
  of dssTerminated: "Terminated"

proc canStart*(state: DebugSessionState): bool =
  state in {dssOff, dssError, dssTerminated}

proc canStop*(state: DebugSessionState): bool =
  state in {dssStarting, dssReady, dssRunning, dssStopped}

proc canContinue*(state: DebugSessionState): bool =
  state == dssStopped

proc canStep*(state: DebugSessionState): bool =
  state == dssStopped

proc isActive*(state: DebugSessionState): bool =
  state in {dssStarting, dssReady, dssRunning, dssStopped}

proc parseStackFrames*(jsonData: JsonNode): seq[StackFrame] =
  ## Parse a DAP `stackTrace` response body into shared StackFrame objects.
  result = @[]
  if jsonData == nil or not jsonData.hasKey("body"): return
  let body = jsonData["body"]
  if not body.hasKey("stackFrames"): return
  for item in body["stackFrames"]:
    let id = if item.hasKey("id"): item["id"].getInt() else: 0
    let name = if item.hasKey("name"): item["name"].getStr() else: ""
    var source = ""
    var line = 0
    var column = 0
    if item.hasKey("source") and item["source"].hasKey("path"):
      source = item["source"]["path"].getStr()
    if item.hasKey("line"):
      line = fromDAPLine(item["line"].getInt())
    if item.hasKey("column"):
      column = fromDAPLine(item["column"].getInt())
    result.add(StackFrame(id: id, name: name, source: source, line: line, column: column))

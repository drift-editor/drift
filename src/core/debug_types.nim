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

  Scope* = object
    name*: string
    variablesReference*: int
    expensive*: bool

  DebugVariable* = object
    name*: string
    value*: string
    typeName*: string
    variablesReference*: int
    evaluateName*: string
    namedVariables*: int
    indexedVariables*: int

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

proc parseScopes*(jsonData: JsonNode): seq[Scope] =
  ## Parse a DAP `scopes` response body into shared Scope objects.
  result = @[]
  if jsonData == nil or not jsonData.hasKey("body"): return
  let body = jsonData["body"]
  if not body.hasKey("scopes"): return
  for item in body["scopes"]:
    let name = if item.hasKey("name"): item["name"].getStr() else: ""
    let variablesReference = if item.hasKey("variablesReference"): item["variablesReference"].getInt() else: 0
    let expensive = if item.hasKey("expensive"): item["expensive"].getBool() else: false
    result.add(Scope(name: name, variablesReference: variablesReference, expensive: expensive))

proc parseVariables*(jsonData: JsonNode): seq[DebugVariable] =
  ## Parse a DAP `variables` response body into shared DebugVariable objects.
  result = @[]
  if jsonData == nil or not jsonData.hasKey("body"): return
  let body = jsonData["body"]
  if not body.hasKey("variables"): return
  for item in body["variables"]:
    let name = if item.hasKey("name"): item["name"].getStr() else: ""
    let value = if item.hasKey("value"): item["value"].getStr() else: ""
    let typeName = if item.hasKey("type"): item["type"].getStr() else: ""
    let variablesReference = if item.hasKey("variablesReference"): item["variablesReference"].getInt() else: 0
    let evaluateName = if item.hasKey("evaluateName"): item["evaluateName"].getStr() else: ""
    let namedVariables = if item.hasKey("namedVariables"): item["namedVariables"].getInt() else: 0
    let indexedVariables = if item.hasKey("indexedVariables"): item["indexedVariables"].getInt() else: 0
    result.add(DebugVariable(
      name: name,
      value: value,
      typeName: typeName,
      variablesReference: variablesReference,
      evaluateName: evaluateName,
      namedVariables: namedVariables,
      indexedVariables: indexedVariables
    ))

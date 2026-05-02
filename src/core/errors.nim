## Error Handling Module
## Centralized error types and handling

import std/[strformat, options]

type
  ErrorCode* = enum
    # File errors
    ecFileNotFound = "FILE_NOT_FOUND"
    ecFileReadError = "FILE_READ_ERROR"
    ecFileWriteError = "FILE_WRITE_ERROR"
    ecPermissionDenied = "PERMISSION_DENIED"
    ecPathTooLong = "PATH_TOO_LONG"
    
    # Document errors
    ecInvalidPosition = "INVALID_POSITION"
    ecInvalidRange = "INVALID_RANGE"
    ecDocumentEmpty = "DOCUMENT_EMPTY"
    ecLineOutOfBounds = "LINE_OUT_OF_BOUNDS"
    
    # Operation errors
    ecOperationFailed = "OPERATION_FAILED"
    ecInvalidState = "INVALID_STATE"
    ecNotImplemented = "NOT_IMPLEMENTED"
    ecCancelled = "CANCELLED"
    
    # LSP errors
    ecLspNotConnected = "LSP_NOT_CONNECTED"
    ecLspTimeout = "LSP_TIMEOUT"
    ecLspError = "LSP_ERROR"
    ecLspServerNotFound = "LSP_SERVER_NOT_FOUND"
    
    # UI errors
    ecInvalidBounds = "INVALID_BOUNDS"
    ecRenderError = "RENDER_ERROR"
    ecFontNotFound = "FONT_NOT_FOUND"
    
    # Config errors
    ecConfigNotFound = "CONFIG_NOT_FOUND"
    ecConfigParseError = "CONFIG_PARSE_ERROR"
    
    # General errors
    ecUnknown = "UNKNOWN"
    ecOutOfMemory = "OUT_OF_MEMORY"
    ecNotSupported = "NOT_SUPPORTED"

  EditorError* = object
    code*: ErrorCode
    message*: string
    details*: string

# Constructors

proc newError*(code: ErrorCode, message: string, details: string = ""): EditorError =
  EditorError(code: code, message: message, details: details)

# Common error constructors
proc fileNotFound*(path: string): EditorError =
  newError(ecFileNotFound, &"File not found: {path}")

proc fileReadError*(path: string, reason: string): EditorError =
  newError(ecFileReadError, &"Failed to read file: {path}", reason)

proc fileWriteError*(path: string, reason: string): EditorError =
  newError(ecFileWriteError, &"Failed to write file: {path}", reason)

proc invalidPosition*(pos: auto): EditorError =
  newError(ecInvalidPosition, &"Invalid position: {pos}")

proc invalidRange*(reason: string): EditorError =
  newError(ecInvalidRange, &"Invalid range: {reason}")

proc invalidOperation*(op: string, reason: string): EditorError =
  newError(ecOperationFailed, &"Operation '{op}' failed: {reason}")

proc notImplemented*(feature: string): EditorError =
  newError(ecNotImplemented, &"Feature not implemented: {feature}")

proc lspError*(methodName: string, reason: string): EditorError =
  newError(ecLspError, &"LSP error in {methodName}: {reason}")

# Result Type

type
  Result*[T] = object
    case ok*: bool
    of true:
      value*: T
    of false:
      error*: EditorError

proc ok*[T](value: T): Result[T] =
  Result[T](ok: true, value: value)

proc err*[T](error: EditorError): Result[T] =
  Result[T](ok: false, error: error)

proc isOk*[T](r: Result[T]): bool = r.ok
proc isErr*[T](r: Result[T]): bool = not r.ok

proc get*[T](r: Result[T]): T =
  if not r.ok:
    raise newException(ValueError, "Cannot get value from error result: " & r.error.message)
  r.value

proc getError*[T](r: Result[T]): EditorError =
  if r.ok:
    raise newException(ValueError, "Cannot get error from ok result")
  r.error

proc getOrDefault*[T](r: Result[T], default: T): T =
  if r.ok: r.value else: default

proc getOrElse*[T](r: Result[T], default: proc(): T): T =
  if r.ok: r.value else: default()

proc map*[T, U](r: Result[T], fn: proc(t: T): U): Result[U] =
  if r.ok:
    ok(fn(r.value))
  else:
    err[U](r.error)

proc flatMap*[T, U](r: Result[T], fn: proc(t: T): Result[U]): Result[U] =
  if r.ok:
    fn(r.value)
  else:
    err[U](r.error)

proc mapErr*[T](r: Result[T], fn: proc(e: EditorError): EditorError): Result[T] =
  if r.ok:
    r
  else:
    err[T](fn(r.error))

proc unwrap*[T](r: Result[T]): T =
  ## Get value or raise exception with error message
  if r.ok:
    r.value
  else:
    raise newException(ValueError, r.error.message)

# Option to Result conversion

proc toResult*[T](opt: Option[T], error: EditorError): Result[T] =
  if opt.isSome:
    ok(opt.get())
  else:
    err[T](error)

# Error formatting

proc `$`*(err: EditorError): string =
  if err.details.len > 0:
    &"[{err.code}] {err.message} - {err.details}"
  else:
    &"[{err.code}] {err.message}"

proc formatError*(err: EditorError): string =
  result = err.message
  if err.details.len > 0:
    result.add("\nDetails: ")
    result.add(err.details)

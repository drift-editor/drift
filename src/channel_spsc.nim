import std/atomics

type
  ChannelMode* = enum
    SPSC
    MPSC

  SPSCSlot[T] = object
    value: T
    sequence: Atomic[int]

  CacheLinePad = object
    pad: array[64, byte]

  SPSChannel*[T] = ref object
    mode: ChannelMode
    buffer: seq[SPSCSlot[T]]
    mask: int
    head: Atomic[int]
    pad1: CacheLinePad
    tail: Atomic[int]
    pad2: CacheLinePad
    mpscHead: Atomic[int]
    mpscCount: Atomic[int]
    capacity: int
    closed: Atomic[bool]

proc newSPSChannel*[T](size: int, mode: ChannelMode = SPSC): SPSChannel[T] =
  var actualSize = 1
  while actualSize < size:
    actualSize = actualSize shl 1
  result = SPSChannel[T](mode: mode, capacity: actualSize)
  result.buffer = newSeq[SPSCSlot[T]](actualSize)
  result.mask = actualSize - 1
  result.head.store(0, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.closed.store(false, moRelaxed)
  if mode == MPSC:
    result.mpscHead.store(0, moRelaxed)
    result.mpscCount.store(0, moRelaxed)

proc close*[T](c: SPSChannel[T]) =
  c.closed.store(true, moRelease)

proc isClosed*[T](c: SPSChannel[T]): bool =
  c.closed.load(moAcquire)

proc trySendSPSC[T](c: SPSChannel[T], value: T): bool =
  let currentHead = c.head.load(moRelaxed)
  let currentTail = c.tail.load(moAcquire)
  if currentHead - currentTail >= c.capacity:
    return false
  let slot = currentHead and c.mask
  c.buffer[slot].value = value
  c.buffer[slot].sequence.store(currentHead + 1, moRelease)
  c.head.store(currentHead + 1, moRelease)
  return true

proc trySendMPSC[T](c: SPSChannel[T], value: T): bool =
  let count = c.mpscCount.fetchAdd(1, moAcquire)
  if count >= c.capacity:
    discard c.mpscCount.fetchSub(1, moRelease)
    return false
  let myHead = c.mpscHead.fetchAdd(1, moAcquire)
  let slot = myHead and c.mask
  c.buffer[slot].value = value
  c.buffer[slot].sequence.store(myHead + 1, moRelease)
  return true

proc trySend*[T](c: SPSChannel[T], value: T): bool =
  if c.isClosed: return false
  case c.mode
  of SPSC: trySendSPSC(c, value)
  of MPSC: trySendMPSC(c, value)

proc tryReceiveSPSC[T](c: SPSChannel[T], value: var T): bool =
  let currentTail = c.tail.load(moRelaxed)
  let currentHead = c.head.load(moAcquire)
  if currentTail >= currentHead:
    return false
  let slot = currentTail and c.mask
  let seq = c.buffer[slot].sequence.load(moAcquire)
  if seq != currentTail + 1:
    return false
  value = c.buffer[slot].value
  c.tail.store(currentTail + 1, moRelease)
  return true

proc tryReceiveMPSC[T](c: SPSChannel[T], value: var T): bool =
  let currentTail = c.tail.load(moRelaxed)
  let currentHead = c.mpscHead.load(moAcquire)
  if currentTail >= currentHead:
    return false
  let slot = currentTail and c.mask
  let seq = c.buffer[slot].sequence.load(moAcquire)
  if seq != currentTail + 1:
    return false
  value = c.buffer[slot].value
  c.tail.store(currentTail + 1, moRelease)
  discard c.mpscCount.fetchSub(1, moRelease)
  return true

proc tryReceive*[T](c: SPSChannel[T], value: var T): bool =
  case c.mode
  of SPSC: tryReceiveSPSC(c, value)
  of MPSC: tryReceiveMPSC(c, value)

proc capacity*[T](c: SPSChannel[T]): int = c.capacity

proc len*[T](c: SPSChannel[T]): int =
  case c.mode
  of SPSC:
    let h = c.head.load(moRelaxed)
    let t = c.tail.load(moRelaxed)
    result = max(0, h - t)
  of MPSC:
    let h = c.mpscHead.load(moRelaxed)
    let t = c.tail.load(moRelaxed)
    result = max(0, h - t)

proc isEmpty*[T](c: SPSChannel[T]): bool =
  case c.mode
  of SPSC: c.tail.load(moRelaxed) >= c.head.load(moRelaxed)
  of MPSC: c.tail.load(moRelaxed) >= c.mpscHead.load(moRelaxed)

proc isFull*[T](c: SPSChannel[T]): bool =
  case c.mode
  of SPSC: c.head.load(moRelaxed) - c.tail.load(moRelaxed) >= c.capacity
  of MPSC: c.mpscCount.load(moRelaxed) >= c.capacity

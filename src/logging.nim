import std/[
  strutils,
  times
]

type
  LogLevel* = enum
    llTrace, llDebug, llInfo, llWarn, llError

  LogLoc* = object
    filename: string
    line: int

  LogData = object
    lvl: LogLevel
    msg: string
    loc: LogLoc
    time: DateTime
    stack: seq[string]

  FilterFn = proc(ld: LogData): bool
  HandlerFn = proc(ld: LogData)

  LogCallback* = object
    filters: seq[FilterFn]
    handler: HandlerFn

  Logger* = ref object
    callbacks: seq[LogCallback]

  LoggerContext* = object
    logger: Logger
    stack: seq[string]


proc new*[T: Logger](_: typedesc[T]): T = T(callbacks: @[])


proc createLogCallback*(
  handler: HandlerFn,
  filters: seq[FilterFn] = @[]
): LogCallback =
  LogCallback(filters: filters, handler: handler)


proc addCallback*(l: Logger, cb: LogCallback) = l.callbacks.add(cb)


template unset(T: typedesc[LogLoc]): T = T(line: -1)
template isUnset*(ll: LogLoc): bool = ll == LogLoc.unset

proc isValidScopeName(s: string): bool = not (s.len == 0 or '.' in s)


proc with*(l: Logger, scope: string): LoggerContext =
  assert scope.isValidScopeName, "Invalid scope name `$1`" % scope
  LoggerContext(logger: l, stack: @[scope])


proc with*(ctx: LoggerContext, scope: string): LoggerContext =
  assert scope.isValidScopeName, "Invalid scope name `$1`" % scope
  LoggerContext(logger: ctx.logger, stack: ctx.stack & scope)


proc log(l: Logger, ld: LogData) =
  echo ld

  for cb in l.callbacks:
    block handle:
      for filter in cb.filters:
        if filter(ld): break handle

      cb.handler(ld)


proc constructLogData(
  lvl: LogLevel,
  msg: string,
  loc: LogLoc,
  stack = newSeq[string]()
): LogData =
  LogData(
    lvl: lvl,
    msg: msg,
    loc: loc,
    time: now(),
    stack: stack
  )


template log*(
  l: Logger,
  lvl: LogLevel,
  msg: string,
  ll = LogLoc.unset,
  stack = newSeq[string]()
) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  l.log(constructLogData(lvl, msg, loc, stack))


template log*(
  ctx: LoggerContext,
  lvl: LogLevel,
  msg: string,
  ll = LogLoc.unset
) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  ctx.logger.log(lvl, msg, loc, ctx.stack)


template trace*(l: Logger, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  l.log(llTrace, msg, loc)


template debug*(l: Logger, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  l.log(llDebug, msg, loc)


template info*(l: Logger, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  l.log(llInfo, msg, loc)


template warn*(l: Logger, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  l.log(llWarn, msg, loc)


template error*(l: Logger, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  l.log(llError, msg, loc)


template trace*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  ctx.log(llTrace, msg, loc)


template debug*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  ctx.log(llDebug, msg, loc)


template info*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  ctx.log(llInfo, msg, loc)


template warn*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  ctx.log(llWarn, msg, loc)


template error*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const I = instantiationInfo()

  var loc = if ll.isUnset: LogLoc(filename: I.filename, line: I.line) else: ll
  ctx.log(llError, msg, loc)
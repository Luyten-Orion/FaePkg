import std/[
  strformat,
  sequtils,
  strutils,
  terminal,
  tables,
  macros,
  times,
  os
]

type
  LogLevel* = enum
    llTrace = "TRACE"
    llDebug = "DEBUG"
    llInfo = "INFO"
    llWarn = "WARN"
    llError = "ERROR"

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


const
  LogLevelColours = {
    llTrace: fgBlue,
    llDebug: fgGreen,
    llInfo: fgCyan,
    llWarn: fgYellow,
    llError: fgRed
  }.toTable


proc getExpandedFilename(filename: static string): static string =
  # TODO: Replace this with a mechanism exposed by Fae maybe?
  const ProjRoot = getProjectPath() / ".." / ".."
  relativePath(filename, ProjRoot)


proc new*[T: Logger](_: typedesc[T]): T = T(callbacks: @[])


proc init*(
  T: typedesc[LogCallback],
  handler: HandlerFn,
  filters: seq[FilterFn] = @[]
): T =
  T(filters: filters, handler: handler)


proc addCallback*(l: Logger, cb: LogCallback) = l.callbacks.add(cb)


template unset(T: typedesc[LogLoc]): T = T(line: -1)
template isUnset*(ll: LogLoc): bool = ll == LogLoc.unset

proc isValidScopeName(s: string): bool = not (s.len == 0 or '.' in s)


proc with*(l: Logger, scope: string): LoggerContext =
  assert scope.isValidScopeName, "Invalid scope name `$1`" % scope
  LoggerContext(logger: l, stack: @[scope])


proc with*(l: Logger, scopes: varargs[string]): LoggerContext =
  for s in scopes:
    assert s.isValidScopeName, "Invalid scope name `$1`" % s
  LoggerContext(logger: l, stack: @scopes)


proc with*(ctx: LoggerContext, scope: string): LoggerContext =
  assert scope.isValidScopeName, "Invalid scope name `$1`" % scope
  LoggerContext(logger: ctx.logger, stack: ctx.stack & scope)


proc with*(ctx: LoggerContext, scopes: varargs[string]): LoggerContext =
  for s in scopes:
    assert s.isValidScopeName, "Invalid scope name `$1`" % s
  LoggerContext(logger: ctx.logger, stack: ctx.stack & @scopes)


proc log(l: Logger, ld: LogData) =
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
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  l.log(constructLogData(lvl, msg, loc, stack))


template log*(
  ctx: LoggerContext,
  lvl: LogLevel,
  msg: string,
  ll = LogLoc.unset
) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  ctx.logger.log(lvl, msg, loc, ctx.stack)


template trace*(l: Logger, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  l.log(llTrace, msg, loc)


template debug*(l: Logger, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  l.log(llDebug, msg, loc)


template info*(l: Logger, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  l.log(llInfo, msg, loc)


template warn*(l: Logger, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  l.log(llWarn, msg, loc)


template error*(l: Logger, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  l.log(llError, msg, loc)


template trace*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  ctx.log(llTrace, msg, loc)


template debug*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  ctx.log(llDebug, msg, loc)


template info*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  ctx.log(llInfo, msg, loc)


template warn*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  ctx.log(llWarn, msg, loc)


template error*(ctx: LoggerContext, msg: string, ll = LogLoc.unset) =
  const
    I = instantiationInfo(fullPaths=true)
    Fp = getExpandedFilename(I.filename)

  var loc = if ll.isUnset: LogLoc(filename: Fp, line: I.line) else: ll
  ctx.log(llError, msg, loc)


proc consoleLogger*(
  useColour = true,
  showStack = false
): HandlerFn =
  proc handler(ld: LogData) =
    # Format location (filename:line)
    let locStr = ld.loc.filename & ":" & $(ld.loc.line)

    # Format stack trace (if shown)
    let stackStr =
      if showStack and ld.stack.len > 0:
        "::(" & (if useColour: ansiForegroundColorCode(fgMagenta) else: "") &
        ld.stack.join(">") & ansiResetCode & ")"
      else:
        ""

    # Format message (handle multiline)
    let msgStr =
      if '\n' in ld.msg:
        ld.msg.split('\n', 1)[0] & "\n" & (ld.msg.splitLines()[1..^1]
          .filterIt(it.len > 0)
          .mapIt("| " & it)
          .join("\n"))
      else:
        ld.msg

    # Format log level with color
    let levelStr =
      if useColour:
        ansiForegroundColorCode(LogLevelColours[ld.lvl]) & $ld.lvl & ansiResetCode
      else:
        $ld.lvl

    # Build final line
    let line =
      (if '\n' in ld.msg: "-" else: "*") & "[" & levelStr & "]::" & "[" &
      (if useColour: ansiForegroundColorCode(fgGreen) else: "") &
      locStr & (if useColour: ansiResetCode else: "") & "]" &
      stackStr & " " & msgStr

    echo line

  handler


proc filterLogLevel*(lvl: LogLevel): FilterFn =
  proc filter(ld: LogData): bool = lvl > ld.lvl
  filter
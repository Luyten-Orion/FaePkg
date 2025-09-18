# TODO: Reconsider adding groups and having a `LoggerCtx` object, where
# it can be passed down using something like `loggerCtx.tag("foo")`,
# which basically creates a callstack-type thing?
import std/[
  strutils,
  #macros,
  tables,
  times
]

type
  LogLevelKind* = enum
    llTrace = "trace"
    llDebug = "debug"
    llInfo = "info"
    llWarn = "warn"
    llError = "error"

  LogLocation* = object
    filename: string
    line: int

  LogObject* = object
    level: LogLevelKind
    locInfo: LogLocation
    dateTime: DateTime
    message: string
    when defined(debug):
      stackTrace: string

  LogHandler* = proc(log: LogObject)

  LoggerObj = object
    level: LogLevelKind
    handlers: seq[LogHandler]

  Logger* = ref LoggerObj


proc new*(T: typedesc[Logger], level: LogLevelKind): T =
  Logger(level: level)


proc addHandler*(logger: Logger, handler: LogHandler) =
  logger.handlers.add(handler)


proc log(logger: Logger, log: LogObject) =
  for handler in logger.handlers:
    handler(log)


proc constructLogObj(
  level: LogLevelKind,
  locInfo: LogLocation,
  dateTime: DateTime,
  message: string
): LogObject =
  LogObject(
    level: level,
    locInfo: locInfo,
    dateTime: dateTime,
    message: message
  )


template log*(logger: Logger, level: LogLevelKind, message: string, logLoc = LogLocation(line: -1)) =
  const InstInfo = instantiationInfo()

  let logLoc =
    if logLoc.filename == "" and logLoc.line == -1:
      LogLocation(filename: InstInfo.filename, line: InstInfo.line)
    else:
      logLoc

  logger.log(
    constructLogObj(
      level,
      logLoc,
      now(),
      message
    )
  )


template trace*(
  logger: Logger,
  message: string,
  logLoc = LogLocation(line: -1)
) =
  const InstInfo = instantiationInfo()
  logger.log(llTrace, message, LogLocation(
    filename: InstInfo.filename, line: InstInfo.line
  ))


template debug*(
  logger: Logger,
  message: string,
  logLoc = LogLocation(line: -1)
) =
  const InstInfo = instantiationInfo()
  logger.log(llDebug, message, LogLocation(
    filename: InstInfo.filename, line: InstInfo.line
  ))


template info*(
  logger: Logger,
  message: string,
  logLoc = LogLocation(line: -1)
) =
  const InstInfo = instantiationInfo()
  logger.log(llInfo, message, LogLocation(
    filename: InstInfo.filename, line: InstInfo.line
  ))


template warn*(
  logger: Logger,
  message: string,
  logLoc = LogLocation(line: -1)
) =
  const InstInfo = instantiationInfo()
  logger.log(llWarn, message, LogLocation(
    filename: InstInfo.filename, line: InstInfo.line
  ))


template error*(
  logger: Logger,
  message: string,
  logLoc = LogLocation(line: -1)
) =
  const InstInfo = instantiationInfo()
  logger.log(llError, message, LogLocation(
    filename: InstInfo.filename, line: InstInfo.line
  ))


proc stdoutHandler*(log: LogObject) =
  let
    logLvl = ($log.level).toUpperAscii
    src = log.locInfo.filename & ":" & $log.locInfo.line
    timestamp = log.dateTime.format("yyyy-MM-dd HH:mm:ss")

  echo "[$1 $2 $3] $4" % [logLvl, timestamp, src, log.message]
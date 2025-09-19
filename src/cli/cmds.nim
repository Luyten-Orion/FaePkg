import ../logging
import ../engine/processes/psync

type
  FaeCmdKind* = enum
    fkNone, fkSync

  FaeArgs* = object
    skullPath*: string
    projPath*: string
    logLevel*: LogLevel
    case kind*: FaeCmdKind
    of fkNone, fkSync:
      discard


var logger = Logger.new()
let logCtx = logger.with("fae-cli")


# TODO: We should also warn users if there are dependencies that seem identical
# with different casing, since if that's the case, they *may* be the same...
proc syncCmd*(args: FaeArgs) =
  synchronise(args.projPath, logCtx)
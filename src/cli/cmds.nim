import ../engine/processes/pgrab

type
  FaeCmdKind* = enum
    fkNone, fkGrab

  FaeArgs* = object
    skullPath*: string
    projPath*: string
    case kind*: FaeCmdKind
    of fkNone, fkGrab:
      discard


# TODO: We should also warn users if there are dependencies that seem identical
# with different casing, since if that's the case, they *may* be the same...
proc grabCmd*(args: FaeArgs) =
  grab(args.projPath)
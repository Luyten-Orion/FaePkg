type
  FaeCmdKind* = enum
    fkNone, fkGrab

  FaeArgs* = object
    skullPath*: string
    projPath*: string
    case kind*: FaeCmdKind
    of fkNone:
      discard
    of fkGrab:
      discard


proc grabCmd(args: FaeArgs) =
  discard
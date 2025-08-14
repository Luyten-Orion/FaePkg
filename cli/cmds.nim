type
  FaeCmdKind* = enum
    fkGrab

  FaeArgs* = object
    skullPath*: string
    projPath*: string
    case kind*: FaeCmdKind
    of fkGrab:
      discard


proc grabCmd(args: FaeArgs) =
  discard
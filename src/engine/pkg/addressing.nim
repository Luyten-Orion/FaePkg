import std/[strutils, sequtils, strformat, options, uri, os]

import logging
import engine/[
  faever,
  schema
]
import engine/pkg/[
  pmodels
]

template fullLoc*(pkg: PackageData): string =
  [pkg.diskLoc, pkg.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join($DirSep)


proc toId*(dep: DependencyV0, logCtx: LoggerContext): string =
  ## Generates the canonical ID (PID) for a dependency.
  result = [dep.src, dep.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join("/")

  if dep.constr.isNone and dep.refr.isNone:
    logCtx.error("No version constraint or ref found for dependency `$1`" % dep.src)
    quit(1)

  if dep.refr.isSome:
    # 1. Reference: PID = Source + #Ref
    result &= "#" & dep.refr.unsafeGet
  else:
    # 2. Versioned: PID = Source + @Major
    # The major version must be derived from the constraint's lower bound.
    let constr = unsafeGet(dep.constr)
    result &= "@" & $constr.lo.major


proc getFolderName*(src: PackageData): string =
  let splited = src.id.split('/').filterIt(not it.isEmptyOrWhitespace)
  var parts = newSeqOfCap[string](splited.len)

  for part in splited:
    var res = newStringOfCap(part.len)

    for c in part:
      if c == '!':
        res.add("!!")
      elif c.isUpperAscii:
        res.add('!')
        res.add(c.toLowerAscii)
      elif c notin {'a'..'z', '0'..'9', '@', '.'}:
        res.add('_')
        res.add toHex(c.byte).toLowerAscii
      else:
        res.add(c)

    parts.add(res)

  parts.join($DirSep)

proc toPkgData*(dep: DependencyV0, logCtx: LoggerContext): PackageData =
  let baseId = [dep.src, dep.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join("/")

  PackageData(
    id: baseId,
    origin: dep.origin,
    loc: parseUri(&"{dep.scheme}://{dep.src}"),
    subdir: dep.subdir,
    foreignPm: dep.foreignPkgMngr
  )
import std/[
  strformat,
  sequtils,
  strutils,
  options,
  tables,
  uri,
  os
]

import pkg/parsetoml

import logging
import engine/[
  resolution,
  adapters,
  schema,
  faever
]

type
  PackageData* = object
    origin*: string
    id*: string
    loc*: Uri
    srcDir*: string
    subdir*: string
    diskLoc*: string
    foreignPm*: Option[PkgMngrKind]
    entrypoint*: Option[string]

  Package* = object
    data*: PackageData
    constr*: FaeVerConstraint
    refr*: string
    isPseudo*: bool

  UnresolvedPackage* = object
    # TODO: Maybe *don't* reuse PackageData?
    data*: PackageData
    constr*: Option[FaeVerConstraint]
    refr*: Option[string]
    foreignPm*: Option[PkgMngrKind]
  
  Packages* = Table[string, Package]


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


proc toOriginCtx*(pkg: PackageData, logCtx: LoggerContext): OriginContext =
  OriginContext.init(pkg.diskLoc, logCtx)


proc clone*(
  pkg: PackageData,
  logCtx: LoggerContext,
) =
  let
    adapter = origins[pkg.origin]
    originCtx = pkg.toOriginCtx(logCtx)

  # TODO: Do some validation to ensure that this *is* the correct package
  if adapter.isVcs(originCtx): return

  if not adapter.clone(originCtx, $pkg.loc):
    quit("Failed to clone package `" & pkg.id & "`", 1)


proc fetch*(
  pkg: PackageData,
  logCtx: LoggerContext,
) =
  if not origins[pkg.origin].fetch(pkg.toOriginCtx(logCtx), $pkg.loc):
    quit("Failed to fetch package `" & pkg.id & "`", 1)


proc fetch*(
  pkg: PackageData,
  logCtx: LoggerContext,
  refr: string
) =
  if not origins[pkg.origin].fetch(pkg.toOriginCtx(logCtx), $pkg.loc, refr):
    quit("Failed to fetch package `" & pkg.id & "`", 1)


# TODO: Return results or raise exceptions rather than hard quitting
proc checkout*(
  pkg: PackageData,
  logCtx: LoggerContext,
  version: FaeVer
): bool =
  ## Returns true if we successfully checked out the package
  ## Returns true if the package was already checked out
  let
    adapter = origins[pkg.origin]
    originCtx = pkg.toOriginCtx(logCtx)
  
  var vstr = $version

  # Could switch this to a single `fetch` call and then use `checkout`
  if not adapter.fetch(originCtx, $pkg.loc, "v" & vstr):
    if not adapter.fetch(originCtx, $pkg.loc, vstr):
      return false
  else:
    vstr = "v" & vstr

  if not adapter.checkout(originCtx, vstr):
    return false

  return true


proc checkout*(
  pkg: PackageData,
  logCtx: LoggerContext,
  refr: string
): bool =
  ## Returns true if we successfully checked out the package.
  ## Returns true if the package was already checked out.
  let
    adapter = origins[pkg.origin]
    originCtx = pkg.toOriginCtx(logCtx)

  # We should prefer `v` prefixed versions, we have to support non-prefixed
  # versions for nimble, but if I can move that behaviour out of this code,
  # then it will be done
  #if not adapter.fetch(originCtx, $pkg.loc, refr):
  #  logCtx.error("Failed to fetch package `" & pkg.id & "`")
  #  return false
  discard adapter.fetch(originCtx, $pkg.loc, refr)

  if not adapter.checkout(originCtx, refr):
    logCtx.error("Failed to checkout package `" & pkg.id & "`")
    return false

  return true

proc pseudoversion*(
  pkg: PackageData,
  logCtx: LoggerContext,
  refr: string
): Option[tuple[ver: FaeVer, isPseudo: bool]] =
  origins[pkg.origin].pseudoversion(pkg.toOriginCtx(logCtx), refr)


proc stripPidMarkers*(pid: string): string =
  result = pid

  let idxHash = result.rfind('#')
  if idxHash >= 0:
      result = result[0..<idxHash]

  let idxAt = result.rfind('@')
  if idxAt >= 0:
      result = result[0..<idxAt]
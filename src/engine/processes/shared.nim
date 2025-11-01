import std/[
  strformat,
  sequtils,
  strutils,
  options,
  tables,
  uri,
  os
]

import parsetoml

import ../../logging
import ../[
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
    subdir*: string
    diskLoc*: string
    foreignPm*: Option[PkgMngrKind]

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


# TODO: Figure out a way to gently enforce package IDs having the major version
# suffixed. Possibly add git hooks?
proc toId*(dep: DependencyV0, logCtx: LoggerContext): string =
  ## If `dep.refr` is set, we use that to generate an ID rather than
  ## `dep.constr`.
  result = [dep.src, dep.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join("/")

  # TODO: Move validation logic to a specific `validate` function for schema
  if dep.constr.isNone and dep.refr.isNone:
    logCtx.error("No version constraint or ref found for dependency `$1`" % dep.src)
    quit(1)

  if dep.refr.isSome:
    result &= "#" & dep.refr.unsafeGet
  else:
    if unsafeGet(dep.constr).lo.major != 0:
      result &= "@" & $dep.constr


proc toPkgData*(dep: DependencyV0, logCtx: LoggerContext): PackageData =
  PackageData(
    id: dep.toId(logCtx),
    origin: dep.origin,
    loc: parseUri(&"{dep.scheme}://{dep.src}"),
    subdir: dep.subdir,
    foreignPm: dep.foreignPkgMngr
  )


proc getFolderName*(src: PackageData): string =
  for part in src.id.split('/'):
    for c in part:
      if c == '!': result.add("!!")
      elif c.isUpperAscii:
        result.add('!')
        result.add(c.toLowerAscii)
      elif c notin {'a'..'z', '0'..'9', '@', '.'}:
        result.add('_')
        result.add toHex(c.byte).toLowerAscii
      else:
        result.add(c)
    result.add(DirSep)


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
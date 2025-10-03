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
  
  Packages* = Table[string, Package]


template fullLoc*(pkg: PackageData): string =
  [pkg.diskLoc, pkg.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join($DirSep)


# TODO: Figure out a way to gently enforce package IDs having the major version
# suffixed. Possibly add git hooks?
proc toId*(dep: DependencyV0): string =
  result = [dep.src, dep.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join("/")

  # TODO: Move validation logic to a specific `validate` function for schema
  if dep.constr.isNone and dep.refr.isNone:
    raise ValueError.newException("Dependency has no constraint and no ref!")
  elif dep.constr.isSome and dep.refr.isSome:
    raise ValueError.newException("Dependency has both constraint and ref!")

  if dep.refr.isSome:
    result &= "#" & dep.refr.unsafeGet
  else:
    if unsafeGet(dep.constr).lo.major != 0:
      result &= "@" & $dep.constr


proc toPkgData*(dep: DependencyV0): PackageData =
  PackageData(
    id: dep.toId,
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
      elif c notin {'a'..'z', '0'..'9', '@'}:
        result.add('_')
        result.add toHex(c.byte).toLowerAscii
      else:
        result.add(c)
    result.add(DirSep)


# TODO: Consider tightening the relation between the `resolution` code and
# the package data?
proc declare*(
  graph: DependencyGraph,
  dependent, dependency: PackageData,
  constr: FaeVerConstraint
) =
  graph.link(dependency.id, dependent.id, constr)


proc toOriginCtx*(pkg: PackageData): OriginContext =
  OriginContext(targetDir: pkg.diskLoc)


proc clone*(
  pkg: PackageData
) =
  let adapter = origins[pkg.origin]

  # TODO: Do some validation to ensure that this *is* the correct package
  if adapter.isVcs(pkg.toOriginCtx): return

  if not adapter.clone(pkg.toOriginCtx, $pkg.loc):
    quit("Failed to clone package `" & pkg.id & "`", 1)


proc fetch*(
  pkg: PackageData
) =
  if not origins[pkg.origin].fetch(pkg.toOriginCtx, $pkg.loc):
    quit("Failed to fetch package `" & pkg.id & "`", 1)


proc fetch*(
  pkg: PackageData,
  refr: string
) =
  if not origins[pkg.origin].fetch(pkg.toOriginCtx, $pkg.loc, refr):
    quit("Failed to fetch package `" & pkg.id & "`", 1)


proc checkout*(
  pkg: PackageData,
  version: FaeVer
): bool =
  ## Returns true if we successfully checked out the package
  ## Returns true if the package was already checked out
  let
    adapter = origins[pkg.origin]
    ctx = pkg.toOriginCtx
  
  var vstr = $version

  if not adapter.fetch(ctx, $pkg.loc, "v" & vstr):
    if not adapter.fetch(ctx, $pkg.loc, vstr):
      quit("Failed to fetch package `" & pkg.id & "`", 1)
  else:
    vstr = "v" & vstr

  if not adapter.checkout(ctx, vstr):
    quit("Failed to checkout package `" & pkg.id & "`", 1)


proc checkout*(
  pkg: PackageData,
  refr: string
): bool =
  ## Returns true if we successfully checked out the package.
  ## Returns true if the package was already checked out.
  let adapter = origins[pkg.origin]

  # We should prefer `v` prefixed versions, we have to support non-prefixed
  # versions for nimble, but if I can move that behaviour out of this code,
  # then it will be done
  if not adapter.fetch(pkg.toOriginCtx, $pkg.loc, refr):
    quit("Failed to fetch package `" & pkg.id & "`", 1)

  if not adapter.checkout(pkg.toOriginCtx, refr):
    quit("Failed to checkout package `" & pkg.id & "`", 1)


proc checkout*(
  pkg: Package,
): bool =
  ## Returns true if we successfully checked out the package.
  ## Returns true if the package was already checked out.
  if pkg.isPseudo:
    assert pkg.refr != "", "Pseudoversioned packages must have a ref!"
    checkout(pkg.data, pkg.refr)
  else:
    checkout(pkg.data, pkg.constr.lo)


proc pseudoversion*(
  pkg: PackageData,
  refr: string
): FaeVer =
  origins[pkg.origin].pseudoversion(pkg.toOriginCtx, refr)
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

import ../private/tomlhelpers
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


template fullLoc*(pkg: PackageData): string =
  [pkg.diskLoc, pkg.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join($DirSep)


# TODO: Figure out a way to gently enforce package IDs having the major version
# suffixed.
proc toId*(dep: DependencyV0): string =
  result = [dep.src, dep.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join("/")

  if dep.constr.lo.major != 0:
    result &= "@" & $dep.constr

proc toPkgData*(dep: DependencyV0, diskLoc = ""): PackageData =
  PackageData(
    id: dep.toId,
    origin: dep.origin,
    loc: parseUri(&"{dep.scheme}://{dep.src}"),
    subdir: dep.subdir,
    foreignPm: dep.foreignPkgMngr,
    diskLoc: diskLoc
  )


proc getFolderName*(src: PackageData): string =
  for part in src.id.split('/'):
    for c in part:
      if c == '!': result.add("!!")
      elif c.isUpperAscii:
        result.add('!')
        result.add(c.toLowerAscii)
      # underscores aren't forbidden, but we're using it to signify hex chars
      elif c in {'_', '/', '<', '>', ':', '"', '\\', '|', '?', '*'}:
        result.add('_')
        result.add toHex(c.byte).toLowerAscii
      # TODO: Be a bit more picky, not wanting to indiscriminately replace
      # all non-alphanumeric chars, since some symbols are good
      #elif not c.isAlphaNumeric:
      #  result.add(c)
      #  result.add toHex(c.byte).toLowerAscii
      else:
        result.add(c)
    result.add(DirSep)


proc registerDep*(
  pkgMap: var Table[string, PackageData],
  g: DependencyGraph,
  fromId: string,
  pkgData: PackageData,
  constr: FaeVerConstraint
) =
  let id = pkgData.id

  if id notin pkgMap: pkgMap[id] = pkgData
  g.add(id)
  try:
    g.link(id, fromId, constr)
  except ValueError:
    quit &"Failed to register dependency, invalid constraint {constr}: " & id, 1


proc toOriginCtx(pkg: PackageData): OriginContext =
  OriginContext(
    targetDir: pkg.diskLoc
  )


proc clone*(
  pkg: PackageData
) =
  let adapter = origins[pkg.origin]

  # TODO: Do some validation to ensure that this *is* the correct package
  if adapter.isVcs(pkg.toOriginCtx): return

  if not adapter.clone(pkg.toOriginCtx, $pkg.loc):
    quit("Failed to clone package `" & pkg.id & "`", 1)


proc checkout*(
  pkg: PackageData,
  version: FaeVer
) =
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
) =
  let adapter = origins[pkg.origin]

  # We should prefer `v` prefixed versions, we have to support non-prefixed
  # versions for nimble, but if I can move that behaviour out of this code,
  # then it will be done
  if not adapter.fetch(pkg.toOriginCtx, $pkg.loc, refr):
    quit("Failed to fetch package `" & pkg.id & "`", 1)

  if not adapter.checkout(pkg.toOriginCtx, refr):
    quit("Failed to checkout package `" & pkg.id & "`", 1)
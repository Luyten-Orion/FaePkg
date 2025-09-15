import experimental/results
import std/[
  sequtils,
  strutils,
  options,
  tables,
  sets,
  uri,
  os
]

import parsetoml

import ../foreign/nimble
import ../[
  resolution,
  adapters,
  schema,
  faever
]
import ./shared


proc grabPkg(
  g: DependencyGraph,
  pkg: PackageData,
  depId: string,
) =
  let
    adapter = origins[pkg.origin]
    ctx = OriginContext(targetDir: pkg.diskLoc)

  if not dirExists(ctx.targetDir / ".git"):
    if not adapter.cloneImpl(ctx, $pkg.loc):
      quit("Failed to clone dependency `" & depId & "`", 1)

  let vstr = $g.deps[depId].constraint.lo

  # We should prefer `v` prefixed versions, we have to support non-prefixed
  # versions for nimble, but if I can move that behaviour out of this code,
  # then it will be done
  if not adapter.fetchImpl(ctx, $pkg.loc, "v" & vstr):
    if not adapter.fetchImpl(ctx, $pkg.loc, vstr):
      quit("Failed to fetch version $1 of $2" % [vstr, depId], 1)

  if not adapter.checkoutImpl(ctx, "v" & vstr):
    if not adapter.checkoutImpl(ctx, vstr):
      quit("Failed to checkout version $1 of $2" % [vstr, depId], 1)


proc grab*(projPath: string) =
  var 
    packages: Table[string, ManifestV0]
    pkgMap: Table[string, PackageData]
    changeStack: seq[string]
    g = newGraph()

  if not dirExists(projPath):
    quit("Not a valid directory!", 1)

  if not fileExists(projPath / "package.skull.toml"):
    quit("No `package.skull.toml` found! Not a valid Fae project!", 1)

  # Set up root package
  let root = block:
    let m = parseManifest(projPath / "package.skull.toml", projPath)
    pkgMap[m.package.name] = m.toPkgData
    pkgMap[m.package.name].diskLoc = projPath
    packages[m.package.name] = m
    g.add(m.package.name)

    for dep in m.dependencies.values:
      let pkgData = dep.toPkgData
      pkgMap.registerDep(g, m.package.name, pkgData, dep.constr)

    m.package.name

  changeStack.add root

  while changeStack.len > 0:
    let res = g.resolve(root)

    if res.isErr:
      quit("Dependency resolution failed with conflicts!\n" & $res.error, 1)

    let depId = changeStack.pop()

    if depId notin pkgMap:
      quit("Missing source info for dependency: " & depId, 1)

    template pkg: var PackageData = pkgMap[depId]

    if depId != root:
      # TODO: Move this check out of the loop, only needs to be done once
      if pkg.origin.len == 0:
        quit("Dependency `" & depId & "` has no origin", 1)
      if pkg.origin notin origins:
        quit("No adapter registered for origin `" & pkg.origin & "`", 1)

      if pkg.diskLoc == "":
        pkg.diskLoc = projPath / ".skull" / "packages" / pkg.getFolderName
        ensureDirExists(pkg.diskLoc)

      g.grabPkg(pkg, depId)

      if pkg.foreignPm.isSome and pkg.foreignPm.unsafeGet == pmNimble:
        initNimbleCompat(projPath)
        
        discard

    # TODO: Might not need the `packages` table tbh...
    packages[depId] = parseManifest(
      [pkg.diskLoc, pkg.subdir, "package.skull.toml"]
        .filterIt(not it.isEmptyOrWhitespace)
        .join($DirSep),
      projPath
    )

    for dep in packages[depId].dependencies.values:
      let pkgData = pkgMap.mgetOrPut(dep.toId, dep.toPkgData)
      changeStack.add pkgData.id
      pkgMap.registerDep(g, depId, pkgData, dep.constr)
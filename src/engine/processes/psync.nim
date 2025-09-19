import experimental/results
import std/[
  sequtils,
  strutils,
  options,
  tables,
  sets,
  os
]

import parsetoml

import ../../logging
import ../private/tomlhelpers
#import ../foreign/nimble
import ../[
  resolution,
  adapters,
  schema,
  faever
]
import ./shared


type
  Package = object
    data: PackageData
    constr: Option[FaeVerConstraint]

  GrabProcessCtx* = object
    graph*: DependencyGraph
    # ID -> Package
    packages*: Table[string, Package]
    # Queue of packages that need to be downloaded first before
    # anything else... Needed for pseudoversion support and Nimble compat
    unresolved*: seq[Package]


#[
# TODO: Add some sort of validation to ensure that a package we're grabbing
# isn't imitating another thoughtlessly.
proc grab(
  pkg: PackageData,
  ver: FaeVer
) =
  pkg.clone()
  # TODO: Consider if `pkg.fetch` should be an operation?
  pkg.checkout(ver)


proc grabR*(projPath: string) =
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

      pkg.grab(g.deps[depId].constraint.lo)

      if pkg.foreignPm.isSome and pkg.foreignPm.unsafeGet == pmNimble:
        initNimbleCompat(projPath)
        
        initManifestForNimblePkg(projPath, pkg)

    # TODO: Might not need the `packages` table tbh...
    packages[depId] = parseManifest(
      pkg.fullLoc / "package.skull.toml",
      projPath
    )

    for dep in packages[depId].dependencies.values:
      let pkgData = pkgMap.mgetOrPut(dep.toId, dep.toPkgData)
      changeStack.add pkgData.id
      pkgMap.registerDep(g, depId, pkgData, dep.constr)
]#


proc init(
  T: typedesc[Package],
  pkgData: PackageData,
  constr: FaeVerConstraint
): T =
  T(data: pkgData, constr: some(constr))


proc init(
  T: typedesc[Package],
  pkgData: PackageData
): T =
  T(data: pkgData, constr: none(FaeVerConstraint))


proc synchronise*(projPath: string, logger: LoggerContext) =
  var
    ctx = GrabProcessCtx()
    logger = logger.with("sync")

  let tmpDir = block:
    let res = getTempDir()

    if not dirExists(res):
      logger.error("Unable to create temporary directory!")
      quit(1)

    # Prune any old stuff here
    removeDir(res / "faetemp")
    createDir(res / "faetemp")

    res / "faetemp"

  if not dirExists(projPath):
    logger.error("`$1` is not a valid project directory!" % projPath)
    quit(1)

  createDir(projPath / ".skull" / "packages")

  let rootId = block:
    var m: ManifestV0

    try:
      m = ManifestV0.fromToml(parseFile(projPath / "package.skull.toml"))
    except IOError:
      logger.error("Failed to open `package.skull.toml`!")
      quit(1)
    except TomlError:
      logger.error(
        "Failed to parse `package.skull.toml` because the TOML was malformed!"
      )
      quit(1)

    let rootPkg = PackageData(id: m.package.name, diskLoc: projPath)

    ctx.packages[m.package.name] = Package.init(rootPkg)

    rootPkg.id

  template rootPkg: var Package = ctx.packages[rootId]


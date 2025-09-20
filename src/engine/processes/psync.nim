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

  UnresolvedPackage = object
    data: PackageData
    version: Option[FaeVer]
    refr: Option[string]

  SyncProcessCtx* = ref object
    tmpDir*: string
    graph*: DependencyGraph
    # ID -> Package
    packages*: Table[string, Package]
    # Queue of packages that need to be downloaded first before
    # anything else... Needed for pseudoversion support and Nimble compat
    unresolved*: seq[UnresolvedPackage]


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


proc getFaeTempDir(logCtx: LoggerContext): string =
  ## Returns the temporary directory location for Fae
  let tmpDir = getTempDir()
  if not dirExists(tmpDir):
    logCtx.error([
      "Unable to create temporary directory in `$1`,",
      "since it doesn't exist!"
    ].join(" ") % tmpDir)
    quit(1)
  tmpDir / "faetemp"


proc rootVersionDetector(
  pkgData: PackageData,
  originCtx: OriginContext,
  logCtx: LoggerContext
): FaeVer =
  result = FaeVer(prerelease: "dev")

  let logCtx = logCtx.with("version-detector")
  if pkgData.origin in origins:
    return origins[pkgData.origin].pseudoversion(originCtx, "HEAD")
  # Maybe we need a `fae.cfg` file that can allow people to pass in some
  # default flags?
  logCtx.warn([
    "No version found for package `$1` (the root package),",
    "attempting to use the major from the ID (if present) as the version."
  ].join(" ") % pkgData.id)

  # `@` is an illegal character in the IDs anyway, but rsplit just in case
  let idSplit = pkgData.id.rsplit('@', 1)
  if idSplit.len > 1:
    try:
      if idSplit[1].len > 1 and idSplit[1][0] == 'v':
        return FaeVer(major: idSplit[1][1..^1].parseUint().int)
    except ValueError:
      discard


proc registerDependency(
  ctx: SyncProcessCtx,
  dependency: DependencyV0,
  logCtx: LoggerContext
): PackageData =
  let logCtx = logCtx.with("dependency-registration")
  var pkgData = dependency.toPkgData

  


proc initRootPackage(
  ctx: SyncProcessCtx,
  projPath: string,
  logCtx: LoggerContext
): string =
  ## Initialises the root package and returns its ID
  let logCtx = logCtx.with("root-pkg-init")
  var
    rMan: ManifestV0
    pkgData: PackageData

  try:
    rMan = ManifestV0.fromToml(parseFile(projPath / "package.skull.toml"))
  except IOError:
    logCtx.error("Failed to open `package.skull.toml`!")
    quit(1)
  except TomlError:
    logCtx.error(
      "Failed to parse `package.skull.toml` because the TOML was malformed!"
    )
    quit(1)

  result = rMan.package.name
  pkgData = PackageData(id: result, diskLoc: projPath)
  let originCtx = pkgData.toOriginCtx

  for origin in origins.keys:
    if origins[origin].isVcs(originCtx):
      pkgData.origin = origin
      break

  ctx.packages[result] = Package.init(
    pkgData,
    FaeVerConstraint(lo: rootVersionDetector(pkgData, originCtx, logCtx))
  )


proc synchronise*(projPath: string, logCtx: LoggerContext) =
  var
    logCtx = logCtx.with("sync")
    # TODO: Add override for the temporary directory?
    ctx = SyncProcessCtx(tmpDir: getFaeTempDir(logCtx))

  try:
    removeDir(ctx.tmpDir)
    createDir(ctx.tmpDir)
  except OSError:
    logCtx.error("Unable to create the Fae temporary directory!")
    quit(1)

  if not dirExists(projPath):
    logCtx.error("`$1` is not a valid project directory!" % projPath)
    quit(1)

  createDir(projPath / ".skull" / "packages")

  let rootId = initRootPackage(ctx, projPath, logCtx)
  template rootPkg: var Package = ctx.packages[rootId]

  
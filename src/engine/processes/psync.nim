import experimental/results
import std/[
  sequtils,
  strutils,
  options,
  random,
  tables,
  sets,
  os
]

import parsetoml

import ../../logging
import ../private/tomlhelpers
import ../foreign/nimble
import ../[
  resolution,
  adapters,
  schema,
  faever
]
import ./shared

randomize()

type
  SyncProcessCtx* = ref object
    tmpDir*, rootPkgId*: string
    graph*: DependencyGraph
    # ID -> Package
    packages*: Packages
    # Queue of packages that need to be resolved first before
    # anything else... Needed for pseudoversion support and Nimble compat
    # Dependent ID -> Dependencies
    unresolved*: Table[string, seq[UnresolvedPackage]]


proc init(
  T: typedesc[Package],
  pkgData: PackageData,
  constr: FaeVerConstraint,
  isPseudo = false
): T =
  T(data: pkgData, constr: constr, isPseudo: isPseudo)


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
    let res = origins[pkgData.origin].pseudoversion(originCtx, "HEAD")
    if res.isSome: return res.unsafeGet().ver
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
  dependentId: string,
  dependency: DependencyV0,
  logCtx: LoggerContext
) =
  let logCtx = logCtx.with("dependency-registration")
  if dependency.constr.isNone and dependency.refr.isNone:
    logCtx.error(
      "Dependency `$1` has no version constraint and no reference!" %
      dependency.src
    )
    quit(1)

  var unresPkg = UnresolvedPackage(
    data: dependency.toPkgData,
    refr: dependency.refr,
    constr: dependency.constr,
    foreignPm: dependency.foreignPkgMngr
  )

  ctx.unresolved.mgetOrPut(dependentId, @[]).add(unresPkg)


proc parseManifest(
  ctx: SyncProcessCtx,
  projPath: string,
  pkgData: PackageData,
  logCtx: LoggerContext
): ManifestV0 =
  let
    logCtx = logCtx.with("manifest-parse")
    pkgPath = relativePath(
      projPath,
      projPath / ".skull" / "packages" / pkgData.fullLoc()
    )

  try:
    ManifestV0.fromToml(parseFile(pkgPath / "package.skull.toml"))
  except IOError:
    logCtx.error("Failed to open `$1`! Does it exist?" % 
      pkgPath / "package.skull.toml")
    quit(1)
  except TomlError:
    logCtx.error(
      "Failed to parse `$1` because the TOML was malformed!" %
      pkgPath / "package.skull.toml"
    )
    quit(1)


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
    FaeVerConstraint(lo: rootVersionDetector(pkgData, originCtx, logCtx)),
    true
  )

  for dependency in rMan.dependencies.values:
    registerDependency(ctx, result, dependency, logCtx)


proc randomSuffix(): string =
  const ValidChars = Letters + Digits
  for i in 0..<8:
    result.add(ValidChars.sample())



proc resolvePackage*(
  ctx: SyncProcessCtx,
  unresPkg: UnresolvedPackage,
  logCtx: LoggerContext
): tuple[id: string, constr: FaeVerConstraint] =
  let logCtx = logCtx.with("unresolved-resolver")
  var unresPkg = unresPkg

  template getPkg(id: string): var Package = ctx.packages[id]
  template getSamePkgs(idBase): seq[string] =
    toSeq(ctx.packages.pairs).filterIt(
      it[1].data.id.startsWith(idBase) and it[1].data.loc != unresPkg.data.loc
    ).mapIt(it[0])

  if '#' in unresPkg.data.id:
    # TODO: Proper guard here? Though this case should never happen
    if unresPkg.refr.isNone:
      logCtx.error(
        "Package `$1` has no reference but reserved character `#` is in its ID!" % unresPkg.data.id
      )
      quit(1)

    let
      unresRefr = unresPkg.refr.unsafeGet()
      idBase = unresPkg.data.id.rsplit('#', 1)[0]
    var
      pseuVer = FaeVer.neg()
      samePkgs = getSamePkgs(idBase)

    if samePkgs.len > 0:
      for samePkgId in samePkgs:
        getPkg(samePkgId).data.fetch()
        let pseuRes = getPkg(samePkgId).data.pseudoversion(unresRefr)
        if pseuRes.isNone:
          logCtx.error(
            "Failed to resolve `$1` because it has no commit `$2`" %
            [unresPkg.data.id, unresRefr]
          )
          quit(1)
        
        pseuVer = pseuRes.unsafeGet().ver
        let parts = pseuVer.prerelease.rsplit('.', 2)
    
    else:
      # Handle cloning ourselves
      unresPkg.data.diskLoc = (
        ctx.tmpDir / "packages" / unresPkg.data.getFolderName() & "_" & randomSuffix()
      )

      unresPkg.data.clone()
      if not unresPkg.data.checkout(unresRefr):
        logCtx.error("Failed to resolve `$1` because it has no commit `$2`" % [
          unresPkg.data.id, unresRefr
        ])
        quit(1)
  
      let pseuRes = unresPkg.data.pseudoversion(unresRefr)
      if pseuRes.isNone:
        logCtx.error(
          "Failed to resolve `$1` because it has no commit `$2`" %
          [unresPkg.data.id, unresRefr]
        )
        quit(1)
      
      pseuVer = pseuRes.unsafeGet().ver

    let parts = pseuVer.prerelease.rsplit('.', 2)
    if parts.len < 2 or parts[1] == "19700101010000":
      logCtx.error(
        "Failed to resolve `$1` because it has no commit `$2`" %
        [unresPkg.data.id, unresRefr]
      )
      quit(1)

    result.id = idBase & (if pseuVer.major > 0: "@" & $pseuVer.major else: "")
    unresPkg.data.id = result.id
    if unresPkg.constr.isSome:
      result.constr = unresPkg.constr.unsafeGet()
      if result.constr.lo > pseuVer:
        logCtx.error(
          "Failed to resolve `$1` because it has a lower bound `$2` than `$3`" %
          [unresPkg.data.id, $result.constr.lo, $pseuVer]
        )
        quit(1)
      result.constr.lo = pseuVer
      
    else:
      result.constr = FaeVerConstraint(lo: pseuVer, hi: pseuVer)
    if not ctx.packages.hasKey(result.id):
      ctx.packages[result.id] = Package.init(
        unresPkg.data,
        result.constr,
        true
      )
    return

  else:
    # Versioned packages
    let
      constr = unresPkg.constr.unsafeGet()
      loVer = constr.lo
    var samePkgs = getSamePkgs(unresPkg.data.id)

    for samePkgId in samePkgs:
      getPkg(samePkgId).data.fetch()
      let adapter = origins[getPkg(samePkgId).data.origin]
      var resRef = adapter.resolve(
        getPkg(samePkgId).data.toOriginCtx, "v" & $loVer
      )
      if resRef.isNone:
        resRef = adapter.resolve(
          getPkg(samePkgId).data.toOriginCtx, $loVer
        )

      if resRef.isNone:
        logCtx.error(
          "Failed to resolve `$1` because it has no version `$2`" %
          [unresPkg.data.id, $loVer]
        )
        quit(1)

      result.id = samePkgId
      result.constr = constr
      return

    if samePkgs.len == 0:
      # Clone it ourselves
      result.id = unresPkg.data.id & (
        if loVer.major > 0: "@" & $loVer.major else: ""
      )
      result.constr = constr
      unresPkg.data.diskLoc = (
        ctx.tmpDir / "packages" / unresPkg.data.getFolderName() & "_" & randomSuffix()
      )

      unresPkg.data.clone()
      if not unresPkg.data.checkout(loVer):
        logCtx.error(
          "Failed to resolve `$1` because it has no version `$2`" %
          [unresPkg.data.id, $loVer]
        )
        quit(1)

      ctx.packages[result.id] = Package.init(
        unresPkg.data,
        unresPkg.constr.unsafeGet(),
        false
      )
      return


type
  # Maybe drag this type into `resolution.nim` and build it there?
  ConflictReport = object
    successes*: seq[DependencyConflictSource]
    conflicts*: seq[DependencyConflictSource]

proc conflictReport(conflicts: Conflicts): string =
  const
    ConfOnDepy = " Conflict on dependency: "
    SuccDept = "  Successful dependents:\n"
    ConfDept = "  Conflicting dependents:\n"
    ListArrowLen = 10
  var
    # Dependeny -> ConflictReport
    reports: Table[string, ConflictReport]
    dependentPath: seq[tuple[dependencyId, dependentId: string]]
    finalLen = 2

  # Lol gross code is fun... I figured reports could get pretty big so prealloc
  # the string
  for conflict in conflicts:
    if not reports.hasKey(conflict.dependencyId):
      reports[conflict.dependencyId] = ConflictReport()
      finalLen += ConfOnDepy.len
      finalLen += conflict.dependencyId.len
      finalLen += ConfDept.len
    reports[conflict.dependencyId].conflicts.add(conflict.conflicting)
    let confl = conflict.conflicting
    finalLen += confl.dependentId.len + ListArrowLen + ($confl.constr).len
    for success in conflict.successes:
      if (conflict.dependencyId, success.dependentId) in dependentPath: continue
      finalLen += success.dependentId.len + ListArrowLen + ($success.constr).len
      reports[conflict.dependencyId].successes.add(success)
      dependentPath.add((conflict.dependencyId, success.dependentId))

  result = newStringOfCap(finalLen)
  result &= "\n"
  for depId, report in reports:
    result &= ConfOnDepy & depId & "\n"
    if report.successes.len > 0:
      result &= SuccDept
      for s in report.successes:
        result &= "   - " & s.dependentId & " -> " & $s.constr & "\n"
    if report.conflicts.len > 0:
      result &= "  Conflicting dependents:\n"
      for c in report.conflicts:
        result &= "   - " & c.dependentId & " -> " & $c.constr & "\n"
    result &= "\n"


proc getCommitFromPseuVer(ver: FaeVer): Option[string] =
  let parts = ver.prerelease.rsplit('.', 3)
  if parts.len < 2:
    return none(string)

  let
    dateStr = parts[^2]
    hashStr = parts[^1]

  if dateStr.len != 14 or not dateStr.allCharsInSet({'0'..'9'}):
    return none(string)

  if hashStr.len != 12:
    return none(string)

  return some(hashStr)


proc advanceResolution*(
  projPath: string,
  ctx: SyncProcessCtx,
  logCtx: LoggerContext,
): bool =
  ## Returns true if there were any changes to the graph during this invocation
  # TODO: Maybe make it so we don't rebuild a graph's dependencies if it hasn't
  # changed?
  result = true
  for pkgs in ctx.unresolved.values:
    if pkgs.len > 0: return false

  let logCtx = logCtx.with("resolution-cycle")

  template getPkg(id: string): var Package = ctx.packages[id]

  block ResolutionStage:
    var dependents = toSeq(ctx.unresolved.keys)
    while dependents.len > 0:
      let dependentId = dependents.pop()
      while ctx.unresolved[dependentId].len > 0:
        let unresPkg = ctx.unresolved[dependentId].pop()
        let (dependencyId, version) = ctx.resolvePackage(unresPkg, logCtx)
        if getPkg(dependencyId).data.diskLoc.startsWith(ctx.tmpDir):
          let permDir = projPath / ".skull" / "packages" /
            getPkg(dependencyId).data.getFolderName()
          try:
            moveDir(getPkg(dependencyId).data.diskLoc, permDir)
          except OSError:
            logCtx.warn("Failed to move `$1` to `$2`, attempting to copy..." % [
              getPkg(dependencyId).data.diskLoc, permDir
            ])
            try:
              copyDir(getPkg(dependencyId).data.diskLoc, permDir)
            except OSError:
              logCtx.error("Failed to copy `$1` to `$2`! Quitting..." % [
                getPkg(dependencyId).data.diskLoc, permDir
              ])
              quit(1)
            try:
              removeDir(getPkg(dependencyId).data.diskLoc)
            except OSError:
              logCtx.warn(
                "Couldn't clean up the temporary directory `$1`" %
                getPkg(dependencyId).data.diskLoc
              )
          getPkg(dependencyId).data.diskLoc = permDir
        ctx.graph.link(dependentId, dependencyId, version)

    let resolveRes = ctx.graph.resolve()
    if resolveRes.isErr:
      logCtx.error(conflictReport(resolveRes.error))
      quit(1)

    let success = resolveRes.unsafeGet()
    for pkg in success:
      getPkg(pkg.id).constr = pkg.constr
      let
        ver = pkg.constr.lo
        refr = ver.getCommitFromPseuVer()
      var success: bool
      if refr.isSome:
        # Keep it up to date
        getPkg(pkg.id).refr = refr.unsafeGet()
        success = getPkg(pkg.id).data.checkout(refr.unsafeGet())
      else:
        # Maybe instead grab the fully qualified commit? Hmm
        getPkg(pkg.id).refr = ""
        success = getPkg(pkg.id).data.checkout(ver)

      if not success:
        logCtx.error("Failed to checkout package `" & pkg.id & "`, can't proceed!")
        quit(1)

  block SynchronisationStage:
    block UnlinkTree:
      for pkgId in ctx.graph.edges.keys:
        if pkgId == ctx.rootPkgId: continue
        ctx.graph.unlinkAllDepsOf(pkgId)

    for pkg in ctx.packages.values:
      if pkg.data.foreignPm.isSome:
        case pkg.data.foreignPm.unsafeGet():
        of PkgMngrKind.pmNimble:
          once: initNimbleCompat(projPath)
          initManifestForNimblePkg(projPath, pkg.data)
        
      let pkgMan = parseManifest(ctx, projPath, pkg.data, logCtx)
      for dep in pkgMan.dependencies.values:
        ctx.registerDependency(pkg.data.id, dep, logCtx)


proc synchronise*(projPath: string, logCtx: LoggerContext) =
  let logCtx = logCtx.with("sync")
  # TODO: Add override for the temporary directory?
  var ctx = SyncProcessCtx(tmpDir: getFaeTempDir(logCtx))

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

  ctx.rootPkgId = initRootPackage(ctx, projPath, logCtx)
  #template rootPkg: var Package = ctx.packages[ctx.rootPkgId]

  var resolveGraph = true
  while resolveGraph:
    resolveGraph = advanceResolution(projPath, ctx, logCtx)
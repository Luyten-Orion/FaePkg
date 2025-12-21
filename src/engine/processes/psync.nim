import experimental/results
import std/[
  sequtils,
  strutils,
  options,
  tables,
  sets,
  json,
  os
]

import pkg/parsetoml

import logging
import engine/private/tomlhelpers
import engine/foreign/nimble
import engine/[
  resolution,
  adapters,
  schema,
  faever
]
import engine/processes/[
  shared,
  common
]


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
    data: dependency.toPkgData(logCtx),
    refr: dependency.refr,
    constr: dependency.constr,
    foreignPm: dependency.foreignPkgMngr
  )

  ctx.unresolved.mgetOrPut(dependentId, @[]).add(unresPkg)


proc parseManifest(
  ctx: SyncProcessCtx,
  pkgData: PackageData,
  logCtx: LoggerContext
): ManifestV0 =
  let
    logCtx = logCtx.with("manifest-parse")
    pkgPath = relativePath(pkgData.fullLoc(), ctx.projPath)

  try:
    ManifestV0.fromToml(parsetoml.parseFile(pkgData.fullLoc() / "package.skull.toml"))
  except IOError:
    logCtx.error("Failed to open `$1`! Does it exist?" % 
      (pkgPath / "package.skull.toml"))
    quit(1)
  except TomlError:
    logCtx.error(
      "Failed to parse `$1` because the TOML was malformed!" %
      pkgPath / "package.skull.toml"
    )
    quit(1)


proc initRootPackage(
  ctx: SyncProcessCtx,
  logCtx: LoggerContext
): string =
  ## Initialises the root package and returns its ID
  let logCtx = logCtx.with("root-pkg-init")
  var
    rMan: ManifestV0
    pkgData: PackageData

  try:
    rMan = ManifestV0.fromToml(parsetoml.parseFile(ctx.projPath / "package.skull.toml"))
  except IOError:
    logCtx.error("Failed to open `package.skull.toml`!")
    quit(1)
  except TomlError:
    logCtx.error(
      "Failed to parse `package.skull.toml` because the TOML was malformed!"
    )
    quit(1)

  result = rMan.package.name
  pkgData = PackageData(id: result, diskLoc: ctx.projPath, srcDir: rMan.package.srcDir)
  let originCtx = pkgData.toOriginCtx(logCtx)

  for origin in origins.keys:
    if origins[origin].isVcs(originCtx):
      pkgData.origin = origin
      break

  let resolvedVer = rootVersionDetector(pkgData, originCtx, logCtx)

  ctx.packages[result] = Package.init(
    pkgData,
    # Force exact match
    FaeVerConstraint(lo: resolvedVer, hi: resolvedVer),
    true
  )

  for dependency in rMan.dependencies.values:
    registerDependency(ctx, result, dependency, logCtx)


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


proc getResolvedConstraint*(
  ctx: SyncProcessCtx,
  unresPkg: UnresolvedPackage,
  logCtx: LoggerContext
): tuple[id: string, constr: FaeVerConstraint] =
  ## Maps an UnresolvedPackage from a manifest line to a canonical ID and
  ## its constraint for the graph.
  let logCtx = logCtx.with("constraint-mapper")

  # Handle packages defined by a *reference* (e.g., commit hash or branch/tag)
  if unresPkg.refr.isSome:
    let refr = unresPkg.refr.unsafeGet()
    
    result.id = unresPkg.data.id & "#" & refr
    
    # Reference-based dependencies must be an *exact match*
    result.constr = unresPkg.constr.get(FaeVerConstraint(
      lo: FaeVer.low, hi: FaeVer.low
    ))
    return

  if unresPkg.constr.isNone:
    logCtx.error("Versioned dependency `$1` has no constraint!" % unresPkg.data.id)
    quit(1)

  result.id = unresPkg.data.id & "@" & $unresPkg.constr.unsafeGet().lo.major
  result.constr = unresPkg.constr.unsafeGet()


proc advanceResolution*(
  ctx: SyncProcessCtx,
  logCtx: LoggerContext,
): bool =
  template pkgSnapshot: HashSet[tuple[id: string, constr: FaeVerConstraint]] =
    toSeq(ctx.packages.values).mapIt((it.data.id, it.constr)).toHashSet()

  let
    logCtx = logCtx.with("resolution-cycle")
    versionSnapshot = pkgSnapshot()
    unresolvedCount = toSeq(ctx.unresolved.values).foldl(a + b.len, 0)

  if unresolvedCount == 0:
    return false

  block GraphBuildingStage:
    var dependents = toSeq(ctx.unresolved.keys)
    while dependents.len > 0:
      let dependentId = dependents.pop()
      while ctx.unresolved[dependentId].len > 0:
        let unresPkg = ctx.unresolved[dependentId].pop()
        
        let (dependencyId, constr) = ctx.getResolvedConstraint(unresPkg, logCtx)
        ctx.graph.link(dependentId, dependencyId, constr)
        
        if not ctx.sourceMap.hasKey(dependencyId):
            ctx.sourceMap[dependencyId] = unresPkg
            
    ctx.unresolved.clear()

  block GraphResolutionStage:
    let resolveRes = ctx.graph.resolve()
    if resolveRes.isErr:
      logCtx.error("Dependency conflict detected:\n" & conflictReport(resolveRes.error))
      quit(1)

    let narrowedConstraints = resolveRes.unsafeGet()
    
    let currentResolvedPIDs = narrowedConstraints.mapIt((it.id, it.constr)).toHashSet()
    let changedPIDs = currentResolvedPIDs - versionSnapshot
    
    if changedPIDs.len == 0:
      logCtx.trace("No changes to resolved package constraints. Skipping I/O.")
      return false

    logCtx.trace("Synchronising " & $changedPIDs.len & " package constraints that changed.")

    var packagesSyncedInThisCycle: HashSet[string]

    for pkgConstraint in narrowedConstraints:
      let
        pid = pkgConstraint.id
        finalConstr = pkgConstraint.constr
        minimalVer = finalConstr.lo

      var pkgData: PackageData
      var needsSync = true
      var wasClonedToTemp = false

      if ctx.packages.hasKey(pid):
        pkgData = ctx.packages[pid].data

        if ctx.packages[pid].constr == finalConstr:
            needsSync = false
            if pid.rsplit('#', 1).len > 1:
                let currentRefr = ctx.packages[pid].refr
                let newRefr = pid.rsplit('#', 1)[1]
                if currentRefr != newRefr:
                    needsSync = true
        
        if pkgData.diskLoc.startsWith(ctx.tmpDir):
            wasClonedToTemp = true
            
      else:
        if not ctx.sourceMap.hasKey(pid):
            logCtx.error("Internal error: Package data for PID `$1` not found for I/O setup." % pid)
            quit(1)
            
        let sourcePkg = ctx.sourceMap[pid]
        
        pkgData = sourcePkg.data
        pkgData.id = pid 


      if needsSync:
        let permDir = ctx.projPath / ".skull" / "packages" / pkgData.getFolderName()
        
        if not dirExists(permDir):
          pkgData.diskLoc = (
            ctx.tmpDir / "packages" / randomSuffix(pkgData.getFolderName())
          )
          pkgData.clone(logCtx)
          wasClonedToTemp = true
        else:
          pkgData.diskLoc = permDir
          pkgData.fetch(logCtx)

        let refrPart = pid.rsplit('#', 1)
        if refrPart.len > 1:
          let refr = refrPart[1]
          if not pkgData.checkout(logCtx, refr):
            logCtx.error("Failed to checkout reference `$1` for `$2`." % [refr, pid])
            quit(1)
          
          let pseuRes = pkgData.pseudoversion(logCtx, refr)
          let resolvedVer = pseuRes.get((FaeVer.low, false)).ver
          
          ctx.packages[pid] = Package.init(
            pkgData,
            FaeVerConstraint(lo: resolvedVer, hi: resolvedVer),
            true
          )
          
        else:
          if not pkgData.checkout(logCtx, minimalVer):
            logCtx.error("Failed to checkout minimal version `$1` for `$2`." % [$minimalVer, pid])
            quit(1)

          ctx.packages[pid] = Package.init(
            pkgData,
            finalConstr,
            false
          )
        
        packagesSyncedInThisCycle.incl(pid)

      if wasClonedToTemp:
        let permDir = ctx.projPath / ".skull" / "packages" / pkgData.getFolderName()
        let tmpLoc = pkgData.diskLoc
        logCtx.trace("Moving temporary package from `$1` to permanent location `$2`." % [tmpLoc, permDir])

        try:
          moveDir(tmpLoc, permDir)
        except OSError:
          try:
            copyDir(tmpLoc, permDir)
            removeDir(tmpLoc)
          except OSError:
            logCtx.error("Failed to move temporary package from `$1` to permanent location `$2`! Quitting..." % [tmpLoc, permDir])
            quit(1)
        
        pkgData.diskLoc = permDir
        ctx.packages[pid].data.diskLoc = permDir
        
        packagesSyncedInThisCycle.incl(pid)

    block UnlinkAndRequeue:
      for pid in packagesSyncedInThisCycle:
          ctx.graph.unlinkAllDepsOf(pid)
          
          let pkg = ctx.packages[pid]

          if pkg.data.foreignPm.isSome:
            case pkg.data.foreignPm.unsafeGet():
            of PkgMngrKind.pmNimble:
              once: initNimbleCompat(ctx.projPath)
              ctx.packages[pid].data.entrypoint = ctx.initManifestForNimblePkg(
                pkg.data, logCtx
              ).some()
            
          let pkgMan = ctx.parseManifest(pkg.data, logCtx)
          ctx.packages[pid].data.srcDir = pkgMan.package.srcDir

          for dep in pkgMan.dependencies.values:
            ctx.registerDependency(pkg.data.id, dep, logCtx)

  return true


proc generateIndex*(ctx: SyncProcessCtx, logCtx: LoggerContext): FaeIndex =
  ## Generates a FaeIndex from a SyncProcessCtx.
  let logCtx = logCtx.with("index-generator")
  
  template toUnixPath(p: string): string =
    when defined(windows): p.replace('\\', '/') else: p

  result.packages = initTable[string, IndexedPackage]()
  result.depends = initTable[string, seq[DependencyLink]]()

  for pkgId, pkg in ctx.packages.pairs:
    let indexedPkg = IndexedPackage(
      srcDir: toUnixPath(pkg.data.srcDir),
      entrypoint: toUnixPath(pkg.data.entrypoint.get(""))
    )
    # The key for the packages table is the package's full path relative to the project root
    # This is because the index is consumed by the compiler, which needs paths.
    let pkgPath = toUnixPath(relativePath(pkg.data.fullLoc(), ctx.projPath))
    result.packages[pkgPath] = indexedPkg

    result.depends[pkgPath] = newSeq[DependencyLink]()
    if pkg.data.entrypoint.isSome:
      result.depends[pkgPath].add DependencyLink(
        # I think this'll work for Nimble packages that wanna refer to themselves? Maybe?
        namespace: pkg.data.entrypoint.unsafeGet()
      )
    
    else:
      result.depends[pkgPath].add DependencyLink(
        # So packages can refer to themselves
        namespace: pkg.data.id.rsplit('#', 1)[0].rsplit('@', 1)[0].rsplit('/', 1)[1].replace("-", "_")
      )


  for pkgId, pkg in ctx.packages.pairs:
    let dependentPath = toUnixPath(relativePath(pkg.data.fullLoc(), ctx.projPath))
    if not dirExists(pkg.data.fullLoc()): continue
    var dependencyLinks: seq[DependencyLink]

    try:
      let pkgMan = ctx.parseManifest(pkg.data, logCtx)
      for alias, dep in pkgMan.dependencies.pairs:
        # The dependency's original Source ID (e.g., 'github.com/foo/bar')
        let originalDepId = dep.toPkgData(logCtx).id
        var resolvedIID = none(string)
        if ctx.graph.edges.hasKey(pkgId):
          for edge in ctx.graph.edges[pkgId]:
            if edge.dependencyId.startsWith(originalDepId):
              resolvedIID = some(edge.dependencyId)
              break
        
        if resolvedIID.isSome():
          let finalPkg = ctx.packages[resolvedIID.unsafeGet()]
          let finalPkgPath = toUnixPath(relativePath(finalPkg.data.fullLoc(), ctx.projPath))
          if result.packages.hasKey(finalPkgPath):
            let
              link = DependencyLink(
                path: finalPkgPath,
                namespace: alias # The alias used in the dependent's manifest
              )
            dependencyLinks.add(link)

    except Exception as e:
      logCtx.trace("Manifest scan failed for " & pkgId & ": " & e.msg)
      
    if dependencyLinks.len > 0:
      result.depends[dependentPath].add dependencyLinks


proc synchronise*(projPath: string, logCtx: LoggerContext) =
  let logCtx = logCtx.with("sync")
  # TODO: Add override for the temporary directory?
  var ctx = SyncProcessCtx(
    projPath: projPath,
    tmpDir: getFaeTempDir(logCtx),
    graph: DependencyGraph(),
  )

  try:
    removeDir(ctx.tmpDir)
    createDir(ctx.tmpDir)
  except OSError:
    logCtx.error("Unable to create the Fae temporary directory!")
    quit(1)

  if not dirExists(ctx.projPath):
    logCtx.error("`$1` is not a valid project directory!" % ctx.projPath)
    quit(1)
  createDir(ctx.projPath / ".skull" / "packages")

  ctx.rootPkgId = ctx.initRootPackage(logCtx)
  #template rootPkg: var Package = ctx.packages[ctx.rootPkgId]

  var resolveGraph = true
  while resolveGraph:
    resolveGraph = ctx.advanceResolution(logCtx)

  let index = %*ctx.generateIndex(logCtx)

  writeFile(ctx.projPath / ".skull" / "index.json", $index)
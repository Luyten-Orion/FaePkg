import experimental/results
import std/[
  sequtils,
  strutils,
  options,
  tables,
  sets,
  json,
  os,
  uri
]

import pkg/parsetoml

import logging
import engine/private/[
  misc,
  tomlhelpers
]
import engine/[
  faever,
  schema,
  resolution,
  adapters
]

import engine/pkg/[
  addressing,
  pmodels,
  io
]

import engine/foreign/nimble/[
  bridge,
  registry
]

import engine/lock
import engine/processes/contexts
import engine/processes/sync/reporting

proc init(
  T: typedesc[Package],
  pkgData: PackageData,
  constr: FaeVerConstraint,
  isPseudo = false
): T =
  T(data: pkgData, constr: constr, isPseudo: isPseudo)


proc getFaeTempDir(logCtx: LoggerContext): string =
  let tmpDir = getTempDir()
  if not dirExists(tmpDir):
    logCtx.error("Unable to create temporary directory in `$1`!" % tmpDir)
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

  logCtx.warn([
    "No version found for root package `$1`,",
    "attempting to use the major from the ID as the version."
  ].join(" ") % pkgData.id)

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
  if dependency.constr.isNone and dependency.refr.isNone:
    logCtx.error("Dependency `$1` has no constraints!" % dependency.src)
    quit(1)

  var unresPkg = UnresolvedPackage(
    data: dependency.toPkgData(logCtx),
    refr: dependency.refr,
    constr: dependency.constr,
    foreignPm: dependency.foreignPkgMngr
  )
  ctx.unresolved.mgetOrPut(dependentId, @[]).add(unresPkg)


proc getResolvedConstraint*(
  ctx: SyncProcessCtx,
  unresPkg: UnresolvedPackage,
  logCtx: LoggerContext
): tuple[id: string, constr: FaeVerConstraint] =
  
  if unresPkg.refr.isSome:
    let refr = unresPkg.refr.unsafeGet()
    result.id = unresPkg.data.id & "#" & refr
    result.constr = unresPkg.constr.get(FaeVerConstraint(
      lo: FaeVer.low, hi: FaeVer.low
    ))
    return

  if unresPkg.constr.isNone:
    logCtx.error("Versioned dependency `$1` has no constraint!" % unresPkg.data.id)
    quit(1)

  result.id = unresPkg.data.id & "@" & $unresPkg.constr.unsafeGet().lo.major
  result.constr = unresPkg.constr.unsafeGet()


proc populatePackagesFromLock(
  ctx: SyncProcessCtx,
  lockFile: LockFile,
  logCtx: LoggerContext
) =
  let logCtx = logCtx.with("lock-loader")
  for dep in lockFile.dependencies:
    let baseId = dep.name
    
    var pid: string
    if dep.refr.isSome:
      pid = baseId & "#" & dep.refr.get()
    elif dep.version.isSome:
      pid = baseId & "@" & $dep.version.unsafeGet().major
    else:
      logCtx.warn("Skipping locked dependency with no version or ref: " & baseId)
      continue

    var pkgData = PackageData(
      id: pid,
      origin: dep.origin,
      loc: parseUri(dep.src),
      subdir: dep.subDir,
      srcDir: dep.srcDir,
      entrypoint: dep.entrypoint
    )

    pkgData.diskLoc = ctx.projPath / ".skull" / "cache" / pkgData.getFolderName()
  
    var pkg = Package(
      data: pkgData,
      isPseudo: false
    )

    pkg.refr = dep.commit

    if dep.version.isSome:
      let ver = dep.version.unsafeGet()
      pkg.constr = FaeVerConstraint(lo: ver, hi: ver)
    
    ctx.packages[pid] = pkg

proc initRootPackage(
  ctx: SyncProcessCtx,
  logCtx: LoggerContext
): string =
  let logCtx = logCtx.with("root-pkg-init")
  var rMan: ManifestV0

  try:
    rMan = ManifestV0.fromToml(parsetoml.parseFile(ctx.projPath / "package.skull.toml"))
  except IOError, TomlError:
    logCtx.error("Failed to parse root `package.skull.toml`!")
    quit(1)

  result = rMan.package.name
  var pkgData = PackageData(id: result, diskLoc: ctx.projPath, srcDir: rMan.package.srcDir)
  let originCtx = pkgData.toOriginCtx(logCtx)

  for origin in origins.keys:
    if origins[origin].isVcs(originCtx):
      pkgData.origin = origin
      break

  let resolvedVer = rootVersionDetector(pkgData, originCtx, logCtx)

  ctx.packages[result] = Package.init(
    pkgData,
    FaeVerConstraint(lo: resolvedVer, hi: resolvedVer),
    true
  )

  for dependency in rMan.dependencies.values:
    registerDependency(ctx, result, dependency, logCtx)


proc fetchManifest(
  ctx: SyncProcessCtx,
  pkg: var Package,
  logCtx: LoggerContext
): ManifestV0 =
  let 
    adapter = origins[pkg.data.origin]
    originCtx = pkg.data.toOriginCtx(logCtx)
    checkRef = if pkg.refr != "": pkg.refr else: "v" & $pkg.constr.lo

  let content = adapter.catFile(originCtx, checkRef, "package.skull.toml")
  
  if content.isSome:
    try:
      return ManifestV0.fromToml(parsetoml.parseString(content.unsafeGet()))
    except TomlError:
      logCtx.error("Malformed `package.skull.toml` in " & pkg.data.id)
      quit(1)

  if pkg.data.foreignPm == some(pmNimble):
    # Make sure we've updated the nimble cache
    once: initNimbleCompat(ctx.projPath, logCtx)
    
    # The bridge writes the generated TOML to the cache directory
    # Also update the `entrypoint` (since Nimble is a pain in the arse)
    pkg.data.entrypoint = ctx.initManifestForNimblePkg(pkg.data, logCtx).some()
    
    # Read the manifest from the cache
    let cachedManifestPath = pkg.data.diskLoc / "package.skull.toml"
    try:
      return ManifestV0.fromToml(parsetoml.parseFile(cachedManifestPath))
    except IOError:
      logCtx.error("Failed to generate/read Nimble manifest for " & pkg.data.id)
      quit(1)

  logCtx.error("No `package.skull.toml` found for " & pkg.data.id)
  quit(1)


proc advanceResolution(
  ctx: SyncProcessCtx,
  logCtx: LoggerContext,
): bool =
  template pkgSnapshot: HashSet[tuple[id: string, constr: FaeVerConstraint]] =
    toSeq(ctx.packages.values).mapIt((it.data.id, it.constr)).toHashSet()

  let
    logCtx = logCtx.with("resolution-cycle")
    versionSnapshot = pkgSnapshot()
    unresolvedCount = toSeq(ctx.unresolved.values).foldl(a + b.len, 0)

  if unresolvedCount == 0: return false

  # Build the graph go brrr
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

  # Graph resolution, on fail, we dump the conflict report
  let resolveRes = ctx.graph.resolve()
  if resolveRes.isErr:
    logCtx.error("Dependency conflict detected:\n" & conflictReport(resolveRes.error))
    quit(1)

  let narrowedConstraints = resolveRes.unsafeGet()
  let currentResolvedPIDs = narrowedConstraints.mapIt((it.id, it.constr)).toHashSet()
  
  # Update changed packages only
  let changedPIDs = currentResolvedPIDs - versionSnapshot
  
  if changedPIDs.len == 0:
    return false

  logCtx.trace("Synchronising " & $changedPIDs.len & " package constraints.")

  # Sync with metadata
  var processedPids: HashSet[string]

  for pkgConstraint in narrowedConstraints:
    let pid = pkgConstraint.id
    
    # Check if the package was unchanged
    if (pid, pkgConstraint.constr) notin changedPIDs and ctx.packages.hasKey(pid): 
      continue

    let minimalVer = pkgConstraint.constr.lo
    var pkgData: PackageData

    # Init package data
    if ctx.packages.hasKey(pid):
      pkgData = ctx.packages[pid].data
    else:
      if not ctx.sourceMap.hasKey(pid):
        logCtx.error("Internal error: Source missing for " & pid)
        quit(1)
      pkgData = ctx.sourceMap[pid].data
      pkgData.id = pid

    # Point to the Bare Cache
    pkgData.diskLoc = ctx.projPath / ".skull" / "cache" / pkgData.getFolderName()
    
    # 3a. Update/Clone Bare Repo
    if not dirExists(pkgData.diskLoc / "objects"):
      pkgData.cloneBare(logCtx)
    else:
      pkgData.fetch(logCtx) # Fast fetch

    # Resolution
    var finalPkg: Package
    let refrPart = pid.rsplit('#', 1)
    
    if refrPart.len > 1:
      # Ref-based dependency
      let refr = refrPart[1]
      let pseuRes = pkgData.pseudoversion(logCtx, refr)
      let resolvedVer = pseuRes.get((FaeVer.low, false)).ver
      
      finalPkg = Package.init(
        pkgData,
        FaeVerConstraint(lo: resolvedVer, hi: resolvedVer),
        true
      )
      finalPkg.refr = refr
    else:
      # Version-based dependency
      finalPkg = Package.init(pkgData, pkgConstraint.constr, false)
      # If it's a versioned dep, we use `vX.Y.Z`
      finalPkg.refr = "v" & $minimalVer

    ctx.packages[pid] = finalPkg
    processedPids.incl(pid)

  # Manifest parsing
  for pid in processedPids:
    ctx.graph.unlinkAllDepsOf(pid)
    
    var pkg = ctx.packages[pid]
    
    # Peek at the manifest from the bare repo
    let pkgMan = ctx.fetchManifest(pkg, logCtx)
    
    pkg.data.srcDir = pkgMan.package.srcDir
    ctx.packages[pid] = pkg # Update srcDir/entrypoint

    for dep in pkgMan.dependencies.values:
      ctx.registerDependency(pkg.data.id, dep, logCtx)

  return true


proc toFullId(pkg: Package): string =
  let baseId = pkg.data.id.stripPidMarkers()

  # If it's a specific ref (commit hash/branch), use that
  if pkg.refr.len > 0 and not pkg.refr.startsWith("v"):
     return baseId & "#" & pkg.refr
  
  # Otherwise use the version from the constraint (which should be exact)
  return baseId & "@" & $pkg.constr.lo


proc generateIndex*(ctx: SyncProcessCtx, logCtx: LoggerContext): FaeIndex =
  let logCtx = logCtx.with("index-generator")
  
  template toUnixPath(p: string): string =
    when defined(windows): p.replace('\\', '/') else: p

  result.packages = initTable[string, IndexedPackage]()

  # PID to full ID for disambiguation
  var pidToFullId = initTable[string, string]()

  for pid, pkg in ctx.packages:
    let fullId = pkg.toFullId()
    pidToFullId[pid] = fullId
    
    var installLoc: string
    if pid == ctx.rootPkgId:
      installLoc = "."
    else:
      let folderName = pkg.data.getFolderName()
      installLoc = toUnixPath(".skull" / "packages" / folderName)

    # Initialize the package entry
    var idxPkg = IndexedPackage(
      path: installLoc,
      srcDir: toUnixPath(pkg.data.srcDir),
      entrypoint: toUnixPath(pkg.data.entrypoint.get("")),
      dependencies: @[]
    )

    # Add self-reference asap
    let namespace = if pkg.data.entrypoint.isSome:
        pkg.data.entrypoint.unsafeGet()
      else:
        pkg.data.id.stripPidMarkers().split('/')[^1].replace("-", "_")

    idxPkg.dependencies.add DependencyLink(
      package: fullId,
      namespace: namespace
    )

    result.packages[fullId] = idxPkg
  
  for pid, pkg in ctx.packages:
    let fullId = pidToFullId[pid]
    
    # Reconstruct absolute path to parse manifest
    let absPath =
      if pid != ctx.rootPkgId: ctx.projPath / ".skull" / "packages" / pkg.data.getFolderName()
      else: ctx.projPath
    
    if not dirExists(absPath): continue

    try:
      let man = ManifestV0.fromToml(parsetoml.parseFile(absPath / "package.skull.toml"))
      
      for alias, dep in man.dependencies.pairs:
        let declaredIdStart = dep.toPkgData(logCtx).id 
        var resolvedPID = none(string)
        
        if ctx.graph.edges.hasKey(pid):
          for edge in ctx.graph.edges[pid]:
            if edge.dependencyId.startsWith(declaredIdStart):
              resolvedPID = some(edge.dependencyId)
              break
        
        if resolvedPID.isSome():
          let targetPid = resolvedPID.unsafeGet()
          let targetFullId = pidToFullId.getOrDefault(targetPid, "")
          
          if targetFullId.len > 0:
            # Append directly to the package's dependency list
            result.packages[fullId].dependencies.add DependencyLink(
              package: targetFullId,
              namespace: alias
            )

    except Exception as e:
      logCtx.trace("Index scan failed for " & pid & ": " & e.msg)


proc synchronise*(projPath: string, logCtx: LoggerContext) =
  let logCtx = logCtx.with("sync")
  var ctx = SyncProcessCtx(
    projPath: projPath,
    tmpDir: getFaeTempDir(logCtx),
    graph: DependencyGraph(),
  )

  # Setup Directories
  if not dirExists(ctx.projPath): quit("Invalid project path!", 1)
  createDir(ctx.projPath / ".skull" / "packages")
  createDir(ctx.projPath / ".skull" / "cache")

  # Initialise the root...
  ctx.rootPkgId = ctx.initRootPackage(logCtx)

  # Try to load lock file
  var lockFileLoaded = false
  let lockFilePath = ctx.projPath / "fae-lock.toml"
  if fileExists(lockFilePath):
    try:
      let lockFile = fromToml(LockFile, parsetoml.parseFile(lockFilePath))
      ctx.populatePackagesFromLock(lockFile, logCtx)
      
      for pid, pkg in ctx.packages:
        if pid == ctx.rootPkgId: continue
        if not dirExists(pkg.data.diskLoc / "objects"):
          pkg.data.cloneBare(logCtx)
        else:
          pkg.data.fetch(logCtx)

      lockFileLoaded = true
      logCtx.info("Loaded dependencies from lock file.")
    except CatchableError:
      logCtx.warn("Invalid lock file found, resolving dependencies. Error: " & getCurrentExceptionMsg())

  if not lockFileLoaded:
    # Resolution go brrr
    var resolveGraph = true
    while resolveGraph:
      resolveGraph = ctx.advanceResolution(logCtx)

    # Generate and write lock file
    let lockFile = fromSyncCtx(ctx, logCtx)
    writeFile(lockFilePath, dumpToml(lockFile))

  for pid, pkg in ctx.packages:
    # TODO: Make it a list rather than a single ID to exclude (for workspace support)
    if pid == ctx.rootPkgId: continue # Skip root
    
    let installDir = ctx.projPath / ".skull" / "packages" / pkg.data.getFolderName()
    
    # Clones from cache to install dir
    pkg.data.installToSite(installDir, pkg.refr, logCtx)
      
    # If the cache contains the manifest, yoink it since we generated it
    let cachedManifest = pkg.data.diskLoc / "package.skull.toml"
    if fileExists(cachedManifest):
      copyFile(cachedManifest, installDir / "package.skull.toml")

  let index = %*ctx.generateIndex(logCtx)
  writeFile(ctx.projPath / ".skull" / "index.json", $index)
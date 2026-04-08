import std/[os, tables, sets, strutils, options]
import parsetoml
import faepkg/logging
import faepkg/core/[types, interner, state]
import faepkg/logic/[resolver, manifest, lockfile]
import faepkg/io/[git, fs, network]
import faepkg/foreign/nimble

proc executeSync*(projPath: string, logCtx: LoggerContext) =
  logCtx.info("Starting FaePkg Sync (DOD Engine)...")

  var
    symbols = initSymbolTable()
    registry = initRegistryState()
    processedUrls = initHashSet[StringId]()
    queue: seq[PackageId] = @[]

  # --- PHASE 1: DISCOVERY (I/O) ---
  logCtx.info("Phase 1: Discovering dependencies...")
  
  let rootTomlPath = projPath / "package.skull.toml"
  if not fileExists(rootTomlPath):
    logCtx.error("Root manifest not found at: " & rootTomlPath)
    quit(1)

  let
    rootTomlStr = readFile(rootTomlPath)
    rootTomlNode = parsetoml.parseString(rootTomlStr)

  # Extract root package name
  var rootName = "root"
  if rootTomlNode.hasKey("package") and rootTomlNode["package"].kind == TomlValueKind.Table:
    let pkgTable = rootTomlNode["package"].getTable()
    if pkgTable.hasKey("name"): rootName = pkgTable["name"].getStr()

  # Register Root Package
  let
    rootUrlId = symbols.getOrPut(rootName) 
    rootId = registry.addPackage(PackageRecord(
      nameId: symbols.getOrPut(rootName),
      originId: symbols.getOrPut("local"),
      urlId: rootUrlId,
      commitId: symbols.getOrPut(""),
      srcDirId: symbols.getOrPut("src"),
      entrypointId: symbols.getOrPut("lib.nim"),
      subdirId: symbols.getOrPut(""),
      version: FaeVer(prerelease: "pre"), 
      flags: {pfIsRoot, pfLocked}
    ))
  
    lockfilePath = projPath / "fae-lock.toml"

  processedUrls.incl(rootUrlId)

  if fileExists(lockfilePath):
    logCtx.info("Checking fae-lock.toml...")
    let lockValid = parseLockfile(logCtx, readFile(lockfilePath), rootTomlStr, symbols, registry)
    if not lockValid:
      logCtx.info("Lockfile invalidated. Will resolve graph from scratch.")

  parseManifest(logCtx, rootTomlStr, symbols, registry, rootId)

  for edge in registry.edges:
    if edge.dependent == rootId:
      queue.add(edge.dependency)

  # Discovery Loop
  while queue.len > 0:
    let targetId = queue.pop()
    var
      record = registry.packages[targetId.uint32]
      rawUrl = symbols.getString(record.urlId)
    let subdirStr = symbols.getString(record.subdirId)

    # 1. Nimble Override
    if pfForeignNimble in record.flags and "/" notin rawUrl:
      initNimbleCompat(projPath, logCtx)
      let resolvedMap = resolveNimbleNames(projPath, [rawUrl], logCtx)
      if resolvedMap.hasKey(rawUrl):
        rawUrl = resolvedMap[rawUrl]
        let newUrlId = symbols.getOrPut(rawUrl)
        registry.packages[targetId.uint32].urlId = newUrlId
        record.urlId = newUrlId

    # 2. Go-get resolution
    rawUrl = resolveGoGet(logCtx, rawUrl)
    if rawUrl != symbols.getString(record.urlId):
      let resolvedId = symbols.getOrPut(rawUrl)
      registry.packages[targetId.uint32].urlId = resolvedId
      record.urlId = resolvedId

    if processedUrls.contains(record.urlId): continue
    processedUrls.incl(record.urlId)

    let cacheDir = getCachePath(projPath, rawUrl)
    if not dirExists(cacheDir / "objects"):
      if not cloneBare(logCtx, "https://" & rawUrl, cacheDir):
        logCtx.warn("Failed to bare-clone: " & rawUrl)
        continue
    else:
      discard fetch(logCtx, cacheDir)

    # 3. Handle specific git hashes (Pseudoversions)
    # If the constraint mandates a `#hash`, we generate a deterministic FaeVer here.
    # We will search the constraints for this edge to see if a pseudoversion applies.
    for edge in registry.edges:
      if edge.dependency == targetId:
        let constr = registry.constraints[edge.constraint.uint32]
        # Check if the prerelease implies a hash (fallback convention)
        if constr.lo.prerelease != "" and not constr.lo.prerelease.contains('.'):
          let pseudoOpt = generatePseudoversion(logCtx, cacheDir, constr.lo.prerelease)
          if pseudoOpt.isSome:
            # Overwrite the constraint with the absolute synthesized truth
            registry.constraints[edge.constraint.uint32] = FaeVerConstraint(lo: pseudoOpt.get(), hi: pseudoOpt.get())
            registry.packages[targetId.uint32].flags.incl(pfIsPseudo)

    var
      manifestPath = "package.skull.toml"
      nimblePattern = ".nimble"
    if subdirStr != "":
      manifestPath = subdirStr & "/" & manifestPath
      nimblePattern = subdirStr & "/" & nimblePattern

    if pfForeignNimble in record.flags:
      let nimbleFiles = lsFiles(logCtx, cacheDir, "HEAD", nimblePattern)
      if nimbleFiles.len > 0:
        let nimbleContent = catFile(logCtx, cacheDir, "HEAD", nimbleFiles[0])
        if nimbleContent.isSome:
          let preEdgeCount = registry.edges.len
          parseNimbleManifest(logCtx, projPath, nimbleFiles[0], nimbleContent.get(), symbols, registry, targetId)
          for i in preEdgeCount..<registry.edges.len:
            queue.add(registry.edges[i].dependency)
    else:
      let manifestContent = catFile(logCtx, cacheDir, "HEAD", manifestPath)
      if manifestContent.isSome:
        let preEdgeCount = registry.edges.len
        parseManifest(logCtx, manifestContent.get(), symbols, registry, targetId)
        for i in preEdgeCount..<registry.edges.len:
          queue.add(registry.edges[i].dependency)

  # --- PHASE 2: RESOLUTION (Pure Compute) ---
  logCtx.info("Phase 2: Resolving graph constraints...")
  let res = resolveGraph(registry)

  if not res.success:
    logCtx.error("Dependency conflict detected!")
    for badUrlId in res.conflicts: # <-- FIXED: Unpacking StringId directly
      let url = symbols.getString(badUrlId)
      logCtx.error(" -> Conflict on package: " & url)
    quit(1)

  # --- PHASE 3: MATERIALIZATION (I/O) ---
  logCtx.info("Phase 3: Materializing packages to disk...")
  
  for pkg in res.resolved:
    let record = registry.packages[pkg.id.uint32]
    if pfIsRoot in record.flags: continue

    let
      url = symbols.getString(record.urlId)
      versionRef = "v" & $pkg.version.major & "." & $pkg.version.minor & "." & $pkg.version.patch
      cacheDir = getCachePath(projPath, url)
    
      # Prefer exact hash if already provided via pseudoversion, else resolve semantic tag
      commitHashOpt =
        if pfIsPseudo in record.flags: some(pkg.version.prerelease.split(".g")[^1]) 
        else: resolveRef(logCtx, cacheDir, versionRef)
                        
      finalHash = commitHashOpt.get(versionRef)
    
    registry.packages[pkg.id.uint32].commitId = symbols.getOrPut(finalHash)

    let
      fullId = if pfIsPseudo in record.flags:
        url & "#" & finalHash
      else:
        let
          v = pkg.version
          pre = if v.prerelease.len > 0: "-" & v.prerelease else: ""
        url & "@" & $v.major & "." & $v.minor & "." & $v.patch & pre

      installDir = getInstallPath(projPath, fullId)

    if not dirExists(installDir):
      logCtx.info("Installing " & fullId)
      createDir(installDir)
      discard gitExec(logCtx, installDir, ["clone", cacheDir, "."])
      discard checkout(logCtx, installDir, finalHash)

  generateIndexJson(logCtx, projPath, symbols, registry, res.resolved)
  
  let lockOutput = generateLockfile(symbols, registry, res.resolved, rootTomlStr)
  writeFile(projPath / "fae-lock.toml", lockOutput)
  logCtx.info("Wrote fae-lock.toml")

  logCtx.info("Synchronization complete.")
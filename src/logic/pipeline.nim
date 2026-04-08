import std/[os, tables, sets, strutils, options]
import parsetoml
import faepkg/logging
import faepkg/core/[types, interner, state]
import faepkg/logic/[resolver, manifest, lockfile]
import faepkg/io/[git, fs, network]
import faepkg/foreign/nimble

proc executeSync*(projPath: string, logCtx: LoggerContext) =
  var
    symbols = initSymbolTable()
    registry = initRegistryState()
    processedUrls = initHashSet[StringId]()
    queue: seq[PackageId] = @[]

  # --- PHASE 1: DISCOVERY (I/O) ---
  logCtx.debug("Discovering dependencies...")
  
  let rootTomlPath = projPath / "package.skull.toml"
  if not fileExists(rootTomlPath):
    logCtx.error("Root manifest not found at: " & rootTomlPath)
    quit(1)

  let
    rootTomlStr = readFile(rootTomlPath)
    rootTomlNode = parsetoml.parseString(rootTomlStr)

  var rootName = "root"
  if rootTomlNode.hasKey("package") and rootTomlNode["package"].kind == TomlValueKind.Table:
    let pkgTable = rootTomlNode["package"].getTable()
    if pkgTable.hasKey("name"): rootName = pkgTable["name"].getStr()

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
    logCtx.debug("Checking `fae-lock.toml`...")
    let lockValid = parseLockfile(logCtx, readFile(lockfilePath), rootTomlStr, symbols, registry)
    if not lockValid:
      logCtx.info("Lockfile invalidated. Rebuilding...")
      removeFile(lockfilePath)

  parseManifest(logCtx, rootTomlStr, symbols, registry, rootId)

  for edge in registry.edges:
    if edge.dependent == rootId:
      queue.add(edge.dependency)

  while queue.len > 0:
    let targetId = queue.pop()
    var
      record = registry.packages[targetId.uint32]
      rawUrl = symbols.getString(record.urlId)
    let subdirStr = symbols.getString(record.subdirId)

    if pfForeignNimble in record.flags and "/" notin rawUrl:
      initNimbleCompat(projPath, logCtx)
      let resolvedMap = resolveNimbleNames(projPath, [rawUrl], logCtx)
      if resolvedMap.hasKey(rawUrl):
        rawUrl = resolvedMap[rawUrl]
        let newUrlId = symbols.getOrPut(rawUrl)
        registry.packages[targetId.uint32].urlId = newUrlId
        record.urlId = newUrlId

    rawUrl = resolveGoGet(logCtx, rawUrl)
    
    if rawUrl.startsWith("https://"): rawUrl = rawUrl[8..^1]
    elif rawUrl.startsWith("http://"): rawUrl = rawUrl[7..^1]
    if rawUrl.endsWith(".git"): rawUrl = rawUrl[0..^5]

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

    for edge in registry.edges:
      if edge.dependency == targetId:
        let constr = registry.constraints[edge.constraint.uint32]
        if constr.lo.prerelease != "" and not constr.lo.prerelease.contains('.'):
          let pseudoOpt = generatePseudoversion(logCtx, cacheDir, constr.lo.prerelease)
          if pseudoOpt.isSome:
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
  logCtx.debug("Resolving graph...")
  let res = resolveGraph(registry)

  if not res.success:
    logCtx.error("Dependency conflict detected!")
    for badUrlId in res.conflicts: 
      let url = symbols.getString(badUrlId)
      logCtx.error(" -> Conflict on package: " & url)
    quit(1)

  # --- PHASE 3: MATERIALIZATION (I/O) ---
  logCtx.debug("Materializing dependencies...")
  
  for pkg in res.resolved:
    let record = registry.packages[pkg.id.uint32]
    if pfIsRoot in record.flags: continue

    let
      url = symbols.getString(record.urlId)
      versionRef = "v" & $pkg.version.major & "." & $pkg.version.minor & "." & $pkg.version.patch
      cacheDir = getCachePath(projPath, url)
    
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
  logCtx.debug("Wrote fae-lock.toml") # Demoted

  logCtx.info("Dependencies synced.")
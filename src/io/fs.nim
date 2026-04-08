import std/[os, strutils, json]
import faepkg/logging
import faepkg/core/[types, interner, state]

proc getSafePath*(id: string): string =
  var res = newStringOfCap(id.len)
  for c in id:
    # Added '@' and '#' to safely map fully qualified IDs to folder paths
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '/', '@', '#'}:
      res.add(c.toLowerAscii())
    else:
      res.add('_')
  return res

proc getCachePath*(projPath: string, url: string): string =
  result = projPath / ".skull" / "cache" / getSafePath(url)

proc getInstallPath*(projPath: string, fullId: string): string =
  # Now explicitly uses the fullID (URL + Version/Hash)
  result = projPath / ".skull" / "packages" / getSafePath(fullId)

proc generateIndexJson*(
  logCtx: LoggerContext,
  projPath: string,
  symbols: SymbolTable,
  registry: RegistryState,
  resolved: seq[ResolvedPackage]
) =
  let logCtx = logCtx.with("index-generator")
  var rootNode = %*{"packages": {}}

  template toUnixPath(p: string): string =
    when defined(windows): p.replace('\\', '/') else: p

  for pkg in resolved:
    let
      record = registry.packages[pkg.id.uint32]
      url = symbols.getString(record.urlId)
      # 1. Fully qualified versions
      fullId = if pkg.commitId.uint32 != 0 and (pfIsPseudo in record.flags):
        url & "#" & symbols.getString(pkg.commitId)
      else:
        let
          v = pkg.version
          pre = if v.prerelease.len > 0: "-" & v.prerelease else: ""
        url & "@" & $v.major & "." & $v.minor & "." & $v.patch & pre

      # 2. Add the root project and proper relative paths using fullId
      installLoc = if pfIsRoot in record.flags:
        "."
      else:
        toUnixPath(getInstallPath(projPath, fullId).relativePath(projPath))

      # 3. Nimble srcDir and entrypoint rules
      srcDir = symbols.getString(record.srcDirId)
      entrypoint = symbols.getString(record.entrypointId)
      subdir = symbols.getString(record.subdirId)

    # Combine subdir and srcDir 
    var
      finalSrcDir =
        if subdir != "": subdir / (if srcDir == "": "src" else: srcDir)
        else: (if srcDir == "": "src" else: srcDir)

      pkgNode = %*{
        "path": installLoc,
        "srcDir": toUnixPath(finalSrcDir),
        "entrypoint": toUnixPath(entrypoint), 
        "dependencies": []
      }

    let alias = url.split('/')[^1].replace("-", "_")
    pkgNode["dependencies"].add(%*{
      "package": fullId,
      "alias": alias
    })

    # Edge matching via URL deduplication
    for edge in registry.edges:
      let dependentRecord = registry.packages[edge.dependent.uint32]
      
      # If this edge belongs to any record matching our canonical URL...
      if dependentRecord.urlId == record.urlId:
        var depFullId = ""
        let targetUrlId = registry.packages[edge.dependency.uint32].urlId
        
        # Find the canonical resolved version of the target
        for resDep in resolved:
          let resDepRecord = registry.packages[resDep.id.uint32]
          if resDepRecord.urlId == targetUrlId:
            let
              depUrl = symbols.getString(resDepRecord.urlId)
              dv = resDep.version
              dpre = if dv.prerelease.len > 0: "-" & dv.prerelease else: ""
            
            if resDep.commitId.uint32 != 0 and (pfIsPseudo in resDepRecord.flags):
              depFullId = depUrl & "#" & symbols.getString(resDep.commitId)
            else:
              depFullId = depUrl & "@" & $dv.major & "." & $dv.minor & "." & $dv.patch & dpre
            break
        
        if depFullId.len > 0:
          let depAlias = depFullId.split('#')[0].split('@')[0].split('/')[^1].replace("-", "_")
          
          # JSON Safeguard: Prevent duplicate edges if the manifest defined it twice
          var alreadyAdded = false
          for existing in pkgNode["dependencies"].getElems():
            if existing["package"].getStr() == depFullId:
              alreadyAdded = true
              break
          
          if not alreadyAdded:
            pkgNode["dependencies"].add(%*{
              "package": depFullId,
              "alias": depAlias
            })

    rootNode["packages"][fullId] = pkgNode

  let indexPath = projPath / ".skull" / "index.json"
  createDir(projPath / ".skull")
  writeFile(indexPath, rootNode.pretty())
  logCtx.debug("Wrote index.json to " & indexPath)

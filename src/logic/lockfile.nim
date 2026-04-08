import std/[strutils, tables, sha1]
import parsetoml
import faepkg/logging
import faepkg/core/[types, interner, state]
import faepkg/logic/manifest # For parseFaeVer

proc getDependenciesHash*(tomlStr: string): string =
  ## Generates a stable SHA1 hash of the [dependencies] table.
  try:
    let toml = parsetoml.parseString(tomlStr)
    if toml.hasKey("dependencies"):
      return $secureHash($toml["dependencies"])
  except CatchableError:
    discard
  return $secureHash("")

proc generateLockfile*(symbols: SymbolTable, registry: RegistryState, resolved: seq[ResolvedPackage], rootManifestStr: string): string =
  let manifestHash = getDependenciesHash(rootManifestStr)
  var outStr = "format = 0\n"
  outStr &= "manifest-hash = \"" & manifestHash & "\"\n\n"
  
  for pkg in resolved:
    let record = registry.packages[pkg.id.uint32]
    if pfIsRoot in record.flags: continue
    
    let
      name = symbols.getString(record.nameId)
      commit = symbols.getString(pkg.commitId)
      origin = symbols.getString(record.originId)
      url = symbols.getString(record.urlId)
      srcDir = symbols.getString(record.srcDirId)
      subdir = symbols.getString(record.subdirId)
      entrypoint = symbols.getString(record.entrypointId)
      isPseudo = pfIsPseudo in record.flags

      v = pkg.version
      pre = if v.prerelease.len > 0: "-" & v.prerelease else: ""
      versionStr = $v.major & "." & $v.minor & "." & $v.patch & pre

    outStr &= "[[dependencies]]\n"
    outStr &= "name = \"" & name & "\"\n"
    outStr &= "commit = \"" & commit & "\"\n"
    outStr &= "origin = \"" & origin & "\"\n"
    outStr &= "src = \"" & url & "\"\n"
    outStr &= "version = \"" & versionStr & "\"\n"
    outStr &= "refr = \"" & commit & "\"\n" 
    outStr &= "sub-dir = \"" & subdir & "\"\n"
    outStr &= "src-dir = \"" & srcDir & "\"\n"
    if entrypoint != "": outStr &= "entrypoint = \"" & entrypoint & "\"\n"
    outStr &= "is-pseudo = " & (if isPseudo: "true" else: "false") & "\n\n"
  
  return outStr

proc parseLockfile*(logCtx: LoggerContext, tomlStr: string, rootManifestStr: string, symbols: var SymbolTable, registry: var RegistryState): bool =
  ## Returns true if the lockfile was successfully loaded, false if it was invalidated.
  let
    logCtx = logCtx.with("lockfile")
    toml = parsetoml.parseString(tomlStr)
    currentHash = getDependenciesHash(rootManifestStr)

  if toml.hasKey("manifest-hash"):
    let lockedHash = toml["manifest-hash"].getStr()
    if lockedHash != currentHash:
      logCtx.info("Manifest dependencies have changed. Invalidating lockfile...")
      return false
  else:
    logCtx.info("Lockfile missing manifest-hash. Invalidating...")
    return false

  if not toml.hasKey("dependencies"): return true
  
  let depsArray = toml["dependencies"]
  if depsArray.kind != TomlValueKind.Array: return true

  for depNode in depsArray.getElems():
    if depNode.kind != TomlValueKind.Table: continue
    let
      t = depNode.getTable()
      name = if t.hasKey("name"): t["name"].getStr() else: ""
    var url = if t.hasKey("src"): t["src"].getStr() else: ""
    
    # Clean up legacy lockfile pollution
    if url.startsWith("https://"): url = url[8..^1]
    elif url.startsWith("http://"): url = url[7..^1]
    if url.endsWith(".git"): url = url[0..^5]

    let
      commit = if t.hasKey("commit"): t["commit"].getStr() else: ""
      origin = if t.hasKey("origin"): t["origin"].getStr() else: "git"
      srcDir = if t.hasKey("src-dir"): t["src-dir"].getStr() else: ""
      subdir = if t.hasKey("sub-dir"): t["sub-dir"].getStr() else: ""
      entrypoint = if t.hasKey("entrypoint"): t["entrypoint"].getStr() else: ""
      isPseudo = t.hasKey("is-pseudo") and t["is-pseudo"].getBool()
    
    var versionVal = FaeVer()
    if t.hasKey("version"):
      let
        verStr = t["version"].getStr()
        constr = parseConstraint("==" & verStr)
      versionVal = constr.lo

    var flags: set[PackageFlags] = {pfLocked} # Bypass the solver
    if isPseudo: flags.incl(pfIsPseudo)

    let record = PackageRecord(
      nameId: symbols.getOrPut(name),
      originId: symbols.getOrPut(origin),
      urlId: symbols.getOrPut(url),
      commitId: symbols.getOrPut(commit),
      srcDirId: symbols.getOrPut(srcDir),
      entrypointId: symbols.getOrPut(entrypoint),
      subdirId: symbols.getOrPut(subdir),
      version: versionVal,
      flags: flags
    )

    discard registry.addPackage(record)
  
  logCtx.info("Loaded " & $registry.packages.len & " locked dependencies.")
  return true
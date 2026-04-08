import std/[tables, strutils, parseutils]
import parsetoml
import faepkg/logging
import faepkg/core/[types, interner, state]

# --- Version Parsing ---

proc parseFaeVer(s: string): FaeVer =
  var
    res: FaeVer
    idx = 0
    maj, min, pch: uint = 0

  idx += parseUint(s, maj, idx)
  if idx < s.len and s[idx] == '.': inc idx
  idx += parseUint(s, min, idx)
  if idx < s.len and s[idx] == '.': inc idx
  idx += parseUint(s, pch, idx)
  
  (res.major, res.minor, res.patch) = (maj.int, min.int, pch.int)

  if idx < s.len and s[idx] == '-':
    inc idx
    idx += parseWhile(s, res.prerelease, {'0'..'9', 'a'..'z', 'A'..'Z', '-', '.'}, idx)

  if idx < s.len and s[idx] == '+':
    inc idx
    discard parseWhile(s, res.buildMetadata, {'0'..'9', 'a'..'z', 'A'..'Z', '-', '.'}, idx)
    
  return res

proc parseConstraint*(s: string): FaeVerConstraint =
  let cleanStr = s.strip()
  if cleanStr == "" or cleanStr == "*":
    return FaeVerConstraint(lo: FaeVer(), hi: FaeVer(major: int.high))

  var res = FaeVerConstraint(lo: FaeVer(), hi: FaeVer(major: int.high))
  let parts = cleanStr.split(',')

  for part in parts:
    let p = part.strip()
    if p.startsWith(">="):
      res.lo = parseFaeVer(p[2..^1].strip())
    elif p.startsWith("<="):
      res.hi = parseFaeVer(p[2..^1].strip())
    elif p.startsWith(">"):
      let v = parseFaeVer(p[1..^1].strip())
      res.lo = v
      res.excl.add(v)
    elif p.startsWith("<"):
      let v = parseFaeVer(p[1..^1].strip())
      res.hi = v
      res.excl.add(v)
    elif p.startsWith("=="):
      let v = parseFaeVer(p[2..^1].strip())
      res.lo = v
      res.hi = v
    elif p.startsWith("^"):
      let v = parseFaeVer(p[1..^1].strip())
      res.lo = v
      res.hi = FaeVer(major: v.major + 1)
      res.excl.add(res.hi)
    elif p.startsWith("~"):
      let v = parseFaeVer(p[1..^1].strip())
      res.lo = v
      res.hi = FaeVer(major: v.major, minor: v.minor + 1)
      res.excl.add(res.hi)
    else:
      let v = parseFaeVer(p)
      res.lo = v
      res.hi = v

  return res

# --- Manifest Parsing ---

proc parseManifest*(
  logCtx: LoggerContext, 
  tomlStr: string, 
  symbols: var SymbolTable, 
  registry: var RegistryState, 
  dependentId: PackageId
) =
  let
    logCtx = logCtx.with("manifest")
    toml = parsetoml.parseString(tomlStr)

  # 1. Update the dependent package's metadata based on its own manifest
  var
    srcDir = "src"
    entrypoint = "lib.nim"
  
  if toml.hasKey("package") and toml["package"].kind == TomlValueKind.Table:
    let pkgTable = toml["package"].getTable()
    if pkgTable.hasKey("src-dir"): srcDir = pkgTable["src-dir"].getStr()
    elif pkgTable.hasKey("srcDir"): srcDir = pkgTable["srcDir"].getStr()
    
    if pkgTable.hasKey("entrypoint"): entrypoint = pkgTable["entrypoint"].getStr()

  registry.packages[dependentId.uint32].srcDirId = symbols.getOrPut(srcDir)
  registry.packages[dependentId.uint32].entrypointId = symbols.getOrPut(entrypoint)

  # 2. Process Dependencies
  if not toml.hasKey("dependencies"):
    return

  let depsNode = toml["dependencies"]
  if depsNode.kind != TomlValueKind.Table:
    logCtx.error("Manifest 'dependencies' must be a table.")
    quit(1)

  for alias, depNode in depsNode.getTable():
    if depNode.kind != TomlValueKind.Table: continue
    let depTable = depNode.getTable()

    if not depTable.hasKey("src"):
      logCtx.error("Dependency alias '" & alias & "' is missing 'src' URL.")
      quit(1)

    let fullSrc = depTable["src"].getStr()
    var 
      cleanUrl = fullSrc
      depSubdir = ""

    # Legacy fallback
    if depTable.hasKey("subdir"):
      depSubdir = depTable["subdir"].getStr()

    let originStr = if depTable.hasKey("origin"): depTable["origin"].getStr() else: "git"

    let gitIdx = fullSrc.find(".git")
    if gitIdx != -1:
      cleanUrl = fullSrc[0 ..< gitIdx]
      
      if depSubdir == "" and gitIdx + 4 < fullSrc.len and fullSrc[gitIdx + 4] == '/':
        depSubdir = fullSrc[gitIdx + 5 .. ^1]

    # Strip HTTP/HTTPS scheme and any trailing .git to maintain canonical string IDs
    if cleanUrl.startsWith("https://"): cleanUrl = cleanUrl[8..^1]
    elif cleanUrl.startsWith("http://"): cleanUrl = cleanUrl[7..^1]
    if cleanUrl.endsWith(".git"): cleanUrl = cleanUrl[0..^5]

    # We ignore the legacy 'scheme' key entirely now, as pipeline.nim explicitly prepends
    # https:// for standard git operations anyway, which handles 99% of use cases cleanly.
    # TODO: Make it so we can choose between `ssh` and `https`/`http` as a global option?

    let urlId = symbols.getOrPut(cleanUrl)
    
    var constr = FaeVerConstraint(lo: FaeVer(), hi: FaeVer(major: int.high))
    if depTable.hasKey("version"):
      constr = parseConstraint(depTable["version"].getStr())

    var pkgFlags: set[PackageFlags] = {}
    if depTable.hasKey("foreign-pm") and depTable["foreign-pm"].getStr() == "nimble":
      pkgFlags.incl(pfForeignNimble)

    let record = PackageRecord(
      nameId: symbols.getOrPut(alias),
      originId: symbols.getOrPut(originStr),
      urlId: urlId,
      commitId: symbols.getOrPut(""),
      srcDirId: symbols.getOrPut(""),     
      entrypointId: symbols.getOrPut(""), 
      subdirId: symbols.getOrPut(depSubdir),
      version: FaeVer(),
      flags: pkgFlags
    )
    
    let
      dependencyId = registry.addPackage(record)
      constraintId = registry.addConstraint(constr)

    registry.addEdge(DependencyEdge(
      dependent: dependentId,
      dependency: dependencyId,
      constraint: constraintId
    ))
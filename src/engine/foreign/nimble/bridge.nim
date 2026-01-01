import std/[os, tables, uri, options, parseutils, strutils, sequtils, htmlparser, xmltree, httpclient]
import experimental/results
import logging
import engine/[faever, schema, adapters]
import engine/pkg/[
  pmodels,
  addressing,
  io
]
import engine/processes/contexts
import engine/foreign/nimble/[
  manifest,
  registry
]
import engine/private/[tomlhelpers, misc]

# TODO: Add more forges
const HardcodedVcsInfo: Table[string, seq[string]] = {
  "git": @["github.com", "gitlab.com", "codeberg.org"]
}.toTable

# TODO: Replace HTTP client maybe
proc resolveGoGet(logCtx: LoggerContext, url: Uri, dep: var DependencyV0): bool =
  let client = newHttpClient()
  defer: client.close()

  var sUrl = url
  if sUrl.query != "": sUrl.query &= "&"
  sUrl.query &= "go-get=1"

  logCtx.debug "Resolving go-get for: " & $sUrl

  let resp = try:
      client.getContent(sUrl)
    except HttpRequestError as e:
      logCtx.debug "Failed to fetch " & $sUrl & ": " & e.msg
      return false

  let parsed = parseHtml(resp)
  let html = parsed.child("html")
  if html == nil: return false

  let head = html.child("head")
  if head == nil: return false

  let repoInfo = head.findAll("meta")
    .filterIt(it.attr("name") == "go-import")
    .mapIt(it.attr("content"))
    .getOrDefault(0, "")

  if repoInfo == "": return false

  let parts = repoInfo.split(' ', 2)
  if parts.len != 3: return false

  dep.origin = parts[1]
  var parsedUri = parseUri(parts[2])
  dep.scheme = parsedUri.scheme
  parsedUri.scheme = ""
  dep.src = $parsedUri
  return true

proc fetchInfo(logCtx: LoggerContext, gUrl: Uri, dep: var DependencyV0) =
  # This method only works on forges with `go-get`, we should probably
  # add a fallback method, or simply try to use the URL as-is without `go-get`
  var
    sUrl: Uri
    wasHardcoded = false

  for vcs, hosts in HardcodedVcsInfo:
    if gUrl.hostname.toLowerAscii() in hosts:
      wasHardcoded = true
      dep.origin = vcs
      sUrl = gUrl
      sUrl.scheme = ""
      sUrl.hostname = sUrl.hostname.toLowerAscii()
      dep.scheme = gUrl.scheme
      dep.src = $sUrl

  when defined(faeNoGoGet):
    logCtx.error "Failed to resolve " & $gUrl & ", can't proceed (`go-get` support disabled)!"
    quit(1)
  else:
    block GoGetImpl:
      if wasHardcoded: break GoGetImpl
      var resolved = false
      var uris = @[gUrl]
      
      # Handle mixed case by trying lowercase as well
      var hasUpper = false
      for c in gUrl.path:
        if c.isUpperAscii:
          hasUpper = true
          break
      
      if hasUpper:
        var lowerUrl = gUrl
        lowerUrl.path = lowerUrl.path.toLowerAscii()
        uris.insert(lowerUrl, 0) # Try lowercase first

      while uris.len > 0:
        let url = uris.pop()
        if resolveGoGet(logCtx, url, dep):
          resolved = true
          sUrl = parseUri(dep.src) # Update sUrl for subdir processing
          break
      
      if not resolved:
        logCtx.error "Failed to resolve " & $gUrl & ", can't proceed!"
        quit(1)

  # TODO: Support more VCSes, but tbh this is a very low priority
  # thing since I am pretty sure that the only repos in the packages.json rn
  # are git repos, since bitbucket doesn't have free hosting anymore (and
  # bitbucket supports git too)
  if dep.src.endsWith(".git"): dep.src = dep.src[0..^5]

  for name, value in sUrl.query.decodeQuery:
    if name == "subdir":
      dep.subdir = value
      break


proc requireToDep*(logCtx: LoggerContext, s: string): tuple[name: string, decl: DependencyV0] =
  result.decl.foreignPkgMngr = some(pmNimble)

  var idx = 0

  const
    NimbleOps = [
      "==",
      ">",
      "<",
      ">=",
      "<=",
      "^=",
      "~="
    ]

    NimbleReqOpChars = {'#', '=', '>', '<', '^', '~'}

  idx += parseUntil(s, result.name, NimbleReqOpChars, idx)
  result.name = result.name.strip()

  if idx >= s.strip(leading=false).len:
    logCtx.warn [
      "Nimble dependency `$1` has no version constraint, ",
      "resolution will default to HEAD!"
    ].join("") % result.name
    result.decl.refr = some("HEAD")
    return

  if s[idx] == '#':
    if idx + 1 >= s.len:
      logCtx.warn [
        "Was expected a revision for dependency `$1` but got nothing, ",
        "defaulting to HEAD"
      ].join("") % result.name
      return

    inc idx

    # TODO: Commit to version proc
    result.decl.refr = some(s[idx..^1].strip())
    return

  var constr = FaeVerConstraint(hi: FaeVer.high)
  while idx < s.len:
    var op = ""

    idx += s.skipWhitespace(idx)    
    if idx >= s.len: break
    idx += s.parseWhile(op, NimbleReqOpChars, idx)

    if op notin NimbleOps:
      logCtx.warn([
        "Unknown operator `$1` for dependency `$2`, specify it ",
        "manually in your manifest!"
      ].join("") % [op, result.name])
      return

    idx += s.skipWhitespace(idx)
    let res = FaeVer.parse(s, idx)

    if res.isErr:
      logCtx.warn([
        "Malformed version constraint for dependency `$1`, specify it ",
        "manually in your manifest!"
      ].join("") % [result.name])
      return

    case op
    of "==":
      constr = merge(constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: res.unsafeGet
      ))
    of ">":
      constr = merge(constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: FaeVer.high,
        excl: @[res.unsafeGet()]
      ))
    of "<":
      constr = merge(constr, FaeVerConstraint(
        lo: FaeVer.neg(),
        hi: res.unsafeGet(),
        excl: @[res.unsafeGet()]
      ))
    of ">=":
      constr = merge(constr, FaeVerConstraint(
        lo: res.unsafeGet(),
        hi: FaeVer.high()
      ))
    of "<=":
      constr = merge(constr, FaeVerConstraint(
        lo: FaeVer.neg(),
        hi: res.unsafeGet()
      ))
    of "^=":
      constr = merge(constr, FaeVerConstraint(
        lo: res.unsafeGet(),
        hi: res.unsafeGet().nextMajor(),
        excl: @[res.unsafeGet().nextMajor()]
      ))
    of "~=":
      constr = merge(constr, FaeVerConstraint(
        lo: res.unsafeGet(),
        hi: res.unsafeGet().nextMinor(),
        excl: @[res.unsafeGet().nextMinor()]
      ))

  if not constr.isSatisfiable():
    logCtx.warn([
      "Constraint `$1` for dependency `$2` is unsatisfiable, specify it ",
      "manually in your manifest!"
    ].join("") % [$constr, result.name])

  result.decl.constr = some(constr)

proc initManifestForNimblePkg*(
  ctx: SyncProcessCtx,
  pkg: PackageData,
  logCtx: LoggerContext
): string =
  ## The main entry point for Nimble -> Fae translation.
  let adapter = origins[pkg.origin]
  let originCtx = pkg.toOriginCtx(logCtx)
  
  # 1. Identify .nimble file via bare-repo peek
  let files = adapter.lsFile(originCtx, "HEAD", ".nimble")
  if files.len == 0: quit("No nimble manifest found in " & pkg.id, 1)
  
  let content = adapter.catFile(originCtx, "HEAD", files[0]).get("")
  let nbMan = parseNimble(files[0], content)
  result = files[0].splitFile().name

  var deps = nbMan.requiresData.mapIt(requireToDep(logCtx, it)).toTable

  # Clean up system deps
  for name in ["nim", "compiler"]:
    deps.del(name)

  # Registry time
  var unexpanded: Table[string, DependencyV0]
  for name in toSeq(deps.keys):
    if "://" notin name:
      unexpanded[name] = deps[name]
      deps.del(name)
    else:
      fetchInfo(logCtx, parseUri(name), deps[name])

  let expanded = getNimbleExpandedNames(ctx.projPath, toSeq(unexpanded.keys))
  for name, url in expanded:
    var dep = unexpanded[name]
    fetchInfo(logCtx, parseUri(url), dep)
    deps[url] = dep 

  # Yoink internal package names
  var dependencies: Table[string, DependencyV0]
  for name, dep in deps:
    var subPkgData = dep.toPkgData(logCtx)

    subPkgData.diskLoc = ctx.projPath / ".skull" / "cache" / subPkgData.getFolderName()
    
    # If the bare repo doesn't exist, we fetch it now
    if not dirExists(subPkgData.diskLoc / "objects"):
      logCtx.info("Caching metadata for sub-dependency: " & subPkgData.id)
      # We assume the adapter handles bare cloning (e.g., git clone --mirror)
      subPkgData.cloneBare(logCtx)

    let subAdapter = origins[subPkgData.origin]
    let subFiles = subAdapter.lsFile(subPkgData.toOriginCtx(logCtx), "HEAD", ".nimble")
    
    if subFiles.len > 0:
      let nimbleName = subFiles[0].splitFile().name
      dependencies[nimbleName] = dep
    else:
      # Last ditch effort: Use the sub-dependency's ID as a name, but this is likely to fail
      dependencies[subPkgData.id.split('/')[^1]] = dep

  let m = ManifestV0(
    format: 0,
    package: PackageV0(name: pkg.id.stripPidMarkers(), srcDir: nbMan.srcDir),
    dependencies: dependencies
  )

  writeFile(pkg.fullLoc / "package.skull.toml", m.dumpToml())
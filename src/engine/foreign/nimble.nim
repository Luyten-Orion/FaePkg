import std/[
  htmlparser,
  httpclient,
  parseutils,
  parsejson,
  sequtils,
  strutils,
  setutils,
  xmltree,
  options,
  streams,
  tables,
  sets,
  uri,
  os
]

#import std/sugar except collect

import experimental/[
  results
]

import parsetoml

import ../private/tomlhelpers
import ../processes/shared
import ../[
  adapters,
  faever,
  schema
]


template collect(initer: typed, body: untyped): untyped =
  block:
    var it{.inject.} = initer
    body
    it


proc getOrDefault[T](s: seq[T], idx: int, default: T): T =
  if idx < s.len: s[idx]
  else: default

proc getOrDefault[T](s: seq[T], idx: BackwardsIndex, default: T): T =
  s.getOrDefault(s.len - idx.int, default)

proc getOrDefault[T](s: seq[T], idx: int | BackwardsIndex): T =
  s.getOrDefault(idx, default(T))



type
  NimbleManifest* = object
    packageName*: string
    srcDir*: string
    # We aren't parsing them here
    requiresData*: seq[string]

const FaeCompatNimblePkgsUrl {.strdefine.} = "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

# TODO: Maybe make it so we only check once every 60 minutes so we don't
# constantly ping github?
var packagesJsonUpToDate = false
proc initNimbleCompat*(projPath: string) =
  # Should only be ran once per program instantiation anyway
  if packagesJsonUpToDate: return

  ensureDirExists(".skull" / "fae", currDir = projPath)
  let path = projPath / ".skull" / "fae" / "nimblepkgs.json"

  let
    client = newHttpClient()
    resp = try:
        client.getContent(FaeCompatNimblePkgsUrl)
      except HttpRequestError:
        echo "Failed to fetch `packages.json` from github! Using local copy."
        packagesJsonUpToDate = true
        return

  client.close()

  if not fileExists(path):
    writeFile(path, resp)
    packagesJsonUpToDate = true

  if readFile(path) != resp:
    echo "Warning: `packages.json` has been updated!"
    writeFile(path, resp)
    packagesJsonUpToDate = true


proc extractStrings(s: string): seq[string] =
  let 
    possibleStrings = s.split('\"')
    start = possibleStrings[0].startsWith("requires").ord # 1 if we start with requires
  for i in start..possibleStrings.high:
    let str = possibleStrings[i]
    if str.len > 0 and str[0] in Letters + Digits:
      result.add str


proc parseNimble*(file: string): NimbleManifest =
  result.packageName = file.extractFilename()

  let content = readFile(file)
  var inRequire = false

  for line in content.splitLines:
    if line.toLower.startsWith("srcdir"):
      result.srcDir = line[line.find('"') + 1..line.rfind('"') - 1]

    elif (let first = line.find(char.fullSet - Whitespace); line.continuesWith("requires", max(first - 1, 0))):
      inRequire = true
      result.requiresData.add line.extractStrings()

    elif inRequire and (let ind = line.find(char.fullSet - WhiteSpace); ind >= 0 and line[ind] == '\"'):
      result.requiresData.add line.extractStrings()

    else:
      inRequire = false


# TODO: Probably hardcode common hosts like github, gitlab, etc
# TODO: Don't `quit`, we should instead use a smarter reporting system.
proc fetchInfo(gUrl: Uri, dep: var DependencyV0) =
  # This method only works on forges with `go-get`, we should probably
  # add a fallback method, or simply try to use the URL as-is without `go-get`
  var
    isMixedCase: bool
    head: XmlNode
    sUrl: Uri
    uris = newSeqOfCap[Uri](2)

  for c in gUrl.path:
    if c.isUpperAscii:
      isMixedCase = true
      break

  if isMixedCase:
    uris.add(gUrl)
    uris[0].path = uris[0].path.toLower
  uris.add(gUrl)

  while uris.len > 0:
    # There is absoLUTELY a better way to do this, but I have back pain rn
    template quitOrCont =
      if uris.len == 0:
        quit "Failed to resolve $1, can't proceed!" % [$url], 1
      else:
        continue

    var url = uris.pop()

    if url.query != "": url.query &= "&"
    url.query &= "go-get=1"


    let
      client = newHttpClient()
      resp = try:
          client.getContent(url)
        except HttpRequestError:
          quitOrCont
      parsed = parseHtml(resp)

    let html = parsed.child("html")
    if html == nil:
      quitOrCont

    head = html.child("head")
    if head == nil:
      quitOrCont

    sUrl = url
    client.close()


  let repoInfo = head.findAll("meta")
    .filterIt(it.attr("name") == "go-import")
    .mapIt(
      if it == nil:
        quit "Failed to resolve $1, can't proceed!" % [$sUrl], 1
      else: it.attr("content"))
    .getOrDefault(0, "")

  if repoInfo == "":
    quit "Failed to resolve $1, can't proceed!" % [$sUrl], 1

  let
    parts = repoInfo.split(' ', 2)

  if parts.len != 3:
    quit "Failed to resolve $1, can't proceed!" % [$sUrl], 1

  dep.origin = parts[1]
  var parsedUri = parseUri(parts[2])
  dep.scheme = parsedUri.scheme
  parsedUri.scheme = ""
  dep.src = $parsedUri
  # TODO: Support more VCSes, but tbh this is a very low priority
  # thing since I am pretty sure that the only repos in the packages.json rn
  # are git repos, since bitbucket doesn't have free hosting anymore
  if dep.src.endsWith(".git"): dep.src = dep.src[0..^5]

  for name, value in sUrl.query.decodeQuery:
    if name == "subdir":
      dep.subdir = value
      break


proc requireToDep*(s: string): tuple[name: string, decl: DependencyV0] =
  result.decl.foreignPkgMngr = some(pmNimble)
  result.decl.constr = FaeVerConstraint(lo: FaeVer.neg, hi: FaeVer.high)

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
    echo ("Nimble dependency `$1` has no version constraint," &
      "make sure to specify a version in your manifest otherwise" &
      "resolution *will* fail!") % [result.name]
    return

  if s[idx] == '#':
    if idx + 1 >= s.len:
      echo ("Was expected a revision for dependency `$1` but got nothing") %
        [result.name]
      return

    inc idx

    # TODO: Commit to version proc
    result.decl.refr = some(s[idx..^1].strip())

  while idx < s.len:
    var op = ""

    idx += s.skipWhitespace(idx)    
    if idx >= s.len: break
    idx += s.parseWhile(op, NimbleReqOpChars, idx)

    if op notin NimbleOps:
      echo ("Unknown operator `$1` for dependency `$2`, specify it " &
        "manually in your manifest!") % [op, result.name]
      return

    idx += s.skipWhitespace(idx)
    let res = FaeVer.parse(s, idx)

    if res.isErr:
      echo ("Malformed version constraint for dependency `$1`, specify it " &
        "manually in your manifest!") % [result.name]
      return

    case op
    of "==":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: res.unsafeGet
      ))
    of ">":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: FaeVer.high,
        excl: @[res.unsafeGet]
      ))
    of "<":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: FaeVer.neg,
        hi: res.unsafeGet,
        excl: @[res.unsafeGet]
      ))
    of ">=":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: FaeVer.high
      ))
    of "<=":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: FaeVer.neg,
        hi: res.unsafeGet
      ))
    of "^=":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: res.unsafeGet.nextMajor,
        excl: @[res.unsafeGet.nextMajor]
      ))
    of "~=":
      result.decl.constr = merge(result.decl.constr, FaeVerConstraint(
        lo: res.unsafeGet,
        hi: res.unsafeGet.nextMinor,
        excl: @[res.unsafeGet.nextMinor]
      ))

    if not result.decl.constr.isSatisfiable:
      echo ("Constraint for dependency `$1` is unsatisfiable, specify it " &
        "manually in your manifest!") % [result.name]
      return


proc getNimblePkgName(
  pkg: PackageData
): string =
  let nimbleManifests = toSeq(walkFiles(pkg.fullLoc / "*.nimble"))

  if nimbleManifests.len < 1:
    quit("No nimble manifest found for package `" & pkg.id & "`", 1)
  
  elif nimbleManifests.len > 1:
    quit("Multiple nimble manifests found for package `" & pkg.id &
      "`, can't decide!", 1)

  else: nimbleManifests[0].splitFile().name


proc getNimbleExpandedNames*(
  projPath: string,
  namesP: openArray[string]
): Table[string, string] =
  let pkgDataStrm = try:
      openFileStream(projPath / ".skull" / "fae" / "nimblepkgs.json", fmRead)
    except IOError:
      quit("Failed to open `nimblepkgs.json` for Nimble compat!", 1)

  var
    parser: JsonParser
    arrayLevel = 0
  parser.open(pkgDataStrm, "nimblepkgs.json")

  var names = @namesP

  while true:
    parser.next()

    case parser.kind()
    of jsonError, jsonEof:
      quit("Failed to parse `nimblepkgs.json` for Nimble compat!", 1)
    of jsonArrayStart:
      inc arrayLevel
    of jsonArrayEnd:
      dec arrayLevel
      if arrayLevel == 0: break
    of jsonObjectStart:
      # TODO: Do some error reporting please....
      var
        skip = false
        pkgName: string
        pkgUrl: string

      while parser.kind() != jsonObjectEnd:
        parser.next()

        if skip: continue

        if parser.kind() != jsonString:
          quit("Failed to parse `nimblepkgs.json` for Nimble compat!", 1)
        
        let key = parser.str().toLowerAscii()

        if key notin ["name", "url"]:
          parser.next()
          case parser.kind()
          # TODO: Clean up
          of jsonString, jsonInt, jsonFloat, jsonTrue, jsonFalse, jsonArrayEnd, jsonObjectEnd:
            # It'll get dropped during next loop
            continue
          of jsonArrayStart:
            inc arrayLevel
            parser.next()
            while arrayLevel > 1:
              if parser.kind() == jsonArrayStart:
                inc arrayLevel
              elif parser.kind() == jsonArrayEnd:
                dec arrayLevel
              parser.next()
            continue
          else:
            quit("Failed to parse `nimblepkgs.json` for Nimble compat!", 1)

        parser.next()
        if key == "name":
          if parser.str() notin names:
            skip = true
            continue
          pkgName = parser.str()
        elif key == "url":
          pkgUrl = parser.str()

        if pkgName != "" and pkgUrl != "":
          result[pkgName] = pkgUrl
          skip = true
          names.del(names.find(pkgName))

    else:
      quit("Failed to parse `nimblepkgs.json` for Nimble compat!", 1)

  parser.close()


proc `?`*(tbl: Table | OrderedTable): TomlValueRef =
  ## Generic constructor for TOML data. Creates a new `TomlValueKind.Table TomlValueRef`
  result = newTTable()
  for key, val in pairs(tbl): result.tableVal[key] = ?val


proc initManifestForNimblePkg*(
  projPath: string,
  pkg: PackageData
) =
  let
    nimbleName = getNimblePkgName(pkg)
    nbMan = parseNimble(pkg.fullLoc / nimbleName & ".nimble")

  var deps = nbMan.requiresData.map(requireToDep).toTable

  for name in ["nim", "compiler"]:
    if name in deps:
      deps.del(name)

  block:
    var unexpanded: Table[string, DependencyV0]

    for name in toSeq(deps.keys):
      if "://" notin name:
        unexpanded[name] = deps[name]
        deps.del(name)
      else:
        fetchInfo(parseUri(name), deps[name])

    let expanded = getNimbleExpandedNames(projPath, toSeq(unexpanded.keys))

    template keysToHashSet[U](tbl: Table[string, U]): HashSet[string] =
      toSeq(tbl.keys).toHashSet

    let missing = unexpanded.keysToHashSet() - expanded.keysToHashSet()
    if missing.len > 0: quit("Missing dependencies: " & $missing, 1)

    for name, url in expanded:
      deps[url] = unexpanded[name]
      fetchInfo(parseUri(url), deps[url])

  var dependencies: Table[string, DependencyV0]

  for name, dep in deps:
    var pkgData = dep.toPkgData()
    pkgData.diskLoc = projPath / ".skull" / "packages" / pkgData.getFolderName
    ensureDirExists(pkgData.diskLoc)
    pkgData.clone()
    dependencies[pkgData.getNimblePkgName()] = dep


  let m = ManifestV0(
    format: 0,
    package: PackageV0(name: nimbleName, srcDir: nbMan.srcDir),
    dependencies: dependencies
  )

  # TODO: Make TOML serialiser for our types
  writeFile(pkg.fullLoc / "package.skull.toml", m.dumpToml())
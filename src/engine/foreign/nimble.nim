import std/[
  htmlparser,
  httpclient,
  parseutils,
  sequtils,
  strutils,
  setutils,
  xmltree,
  options,
  tables,
  uri,
  os
]

import experimental/[
  results
]

import ../processes/shared

import ../[
  adapters,
  faever,
  schema
]


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

  discard existsOrCreateDir(projPath / ".fae")
  let path = projPath / ".fae" / "nimblepkgs.json"

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
    
    head = parsed.child("head")
    if head == nil:
      quitOrCont

    sUrl = url
    client.close()


  let repoInfo = head.findAll("meta")
    .filterIt(it.attr("name") == "go-import")
    .mapIt(
      if it == nil: quit "Failed to resolve $1, can't proceed!" % [$sUrl], 1
      else: it.attr("content"))
    .getOrDefault(0, "")

  if repoInfo == "":
    quit "Failed to resolve $1, can't proceed!" % [$sUrl], 1

  let
    parts = repoInfo.split(' ', 2)

  if parts.len != 2:
    quit "Failed to resolve $1, can't proceed!" % [$sUrl], 1

  dep.origin = parts[1]
  dep.src = parts[2]
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


proc getNimbleName*(
  projPath, name: string,
  decl: var DependencyV0
): string =
  let
    adapter = origins[decl.origin]
    ctx = OriginContext(targetDir: projPath / ".skull" /
      decl.toPkgData.getFolderName)

  if not adapter.clone(ctx, decl.src):
    quit("Failed to clone dependency `$1`" % [decl.toId], 1)


proc getNimbleNames*(
  projPath: string,
  deps: Table[string, DependencyV0]
): Table[string, DependencyV0] =
  discard
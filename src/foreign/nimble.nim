import std/[httpclient, json, os, parsejson, streams, strutils, parseutils]
import faepkg/logging
import faepkg/core/[types, interner, state]
import faepkg/logic/manifest

const FaeCompatNimblePkgsUrl {.strdefine.} = "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"
var packagesJsonUpToDate = false

proc initNimbleCompat*(projPath: string, logCtx: LoggerContext) =
  if packagesJsonUpToDate: return

  let
    logCtx = logCtx.with("compat", "nimble", "init")
    faeDir = projPath / ".skull" / "fae"
    path = faeDir / "nimblepkgs.json"
    client = newHttpClient()
  defer: client.close()
  createDir(faeDir)

  try:
    let resp = client.getContent(FaeCompatNimblePkgsUrl)
    writeFile(path, resp)
    packagesJsonUpToDate = true
    logCtx.debug("Successfully updated local nimblepkgs.json")
  except CatchableError as e:
    if not fileExists(path):
      logCtx.error("Failed to fetch `packages.json` and no local copy exists! " & e.msg)
      quit(1)
    logCtx.warn("Failed to fetch `packages.json`. Using cached local copy.")
    packagesJsonUpToDate = true

proc resolveNimbleName*(projPath: string, pkgName: string, logCtx: LoggerContext): string =
  ## Scans the cached nimblepkgs.json to find the Git URL for a Nimble package name.
  let
    path = projPath / ".skull" / "fae" / "nimblepkgs.json"
    pkgDataStrm = try:
      openFileStream(path, fmRead)
    except IOError:
      logCtx.error("Failed to open `nimblepkgs.json`. Run initNimbleCompat first.")
      quit(1)

  var parser: JsonParser
  parser.open(pkgDataStrm, "nimblepkgs.json")
  defer: 
    parser.close()
    pkgDataStrm.close()

  let targetName = pkgName.toLowerAscii()
  var arrayLevel = 0

  while true:
    parser.next()
    case parser.kind()
    of jsonError, jsonEof: break 
    of jsonArrayStart: inc arrayLevel
    of jsonArrayEnd:
      dec arrayLevel
      if arrayLevel == 0: break
    of jsonObjectStart:
      var
        currentName = ""
        currentUrl = ""
        skip = false

      while parser.kind() != jsonObjectEnd:
        parser.next()
        if skip: continue
        if parser.kind() != jsonString: continue
        
        let key = parser.str().toLowerAscii()
        parser.next() # Move to value
        
        if key == "name":
          currentName = parser.str().toLowerAscii()
          if currentName != targetName: skip = true
        elif key == "url":
          currentUrl = parser.str()
          
        if currentName == targetName and currentUrl != "":
          return currentUrl # Found it!

    else: discard

  logCtx.warn("Could not resolve Nimble package name: " & pkgName)
  return ""

type
  NimbleManifest* = object
    packageName*: string
    srcDir*: string
    requiresData*: seq[string]

proc extractStrings(s: string): seq[string] =
  let 
    possibleStrings = s.split('\"')
    start = possibleStrings[0].startsWith("requires").ord
  for i in start..possibleStrings.high:
    let str = possibleStrings[i]
    if str.len > 0 and str[0] in Letters + Digits:
      result.add str

proc parseNimble*(file: string, content: string): NimbleManifest =
  result.packageName = file.extractFilename().splitFile().name
  var inRequire = false

  for line in content.splitLines:
    if line.toLower.startsWith("srcdir"):
      result.srcDir = line[line.find('"') + 1..line.rfind('"') - 1]
    elif (let first = line.find(AllChars - Whitespace); line.continuesWith("requires", max(first - 1, 0))):
      inRequire = true
      result.requiresData.add line.extractStrings()
    elif inRequire and (let ind = line.find(AllChars - WhiteSpace); ind >= 0 and line[ind] == '\"'):
      result.requiresData.add line.extractStrings()
    else:
      inRequire = false

proc parseNimbleManifest*(
  logCtx: LoggerContext,
  projPath: string,
  fileName: string,
  content: string,
  symbols: var SymbolTable,
  registry: var RegistryState,
  dependentId: PackageId
) =
  let
    man = parseNimble(fileName, content)
    # 1. Store the exact srcDir and Entrypoint for Phase 3
    baseSrcDir = if man.srcDir != "": man.srcDir else: "src"
    finalSrcDir = baseSrcDir & "/" & man.packageName

  registry.packages[dependentId.uint32].srcDirId = symbols.getOrPut(finalSrcDir)
  registry.packages[dependentId.uint32].entrypointId = symbols.getOrPut("../" & man.packageName & ".nim")

  # 2. Process Transitive Dependencies
  for reqStr in man.requiresData:
    var name = ""
    let idx = parseUntil(reqStr, name, {'#', '=', '>', '<', '^', '~', ' '})
    name = name.strip()
    
    # Ignore system dependencies
    if name == "" or name in ["nim", "compiler"]: continue

    # Resolve the URL
    var rawUrl = name
    if "://" notin rawUrl:
      let resolved = resolveNimbleName(projPath, rawUrl, logCtx)
      if resolved != "": rawUrl = resolved

    let
      urlId = symbols.getOrPut(rawUrl)
      reqVerStr = reqStr[idx..^1].strip()
    var constr = FaeVerConstraint(lo: FaeVer(), hi: FaeVer(major: int.high))
    
    if reqVerStr.len > 0:
      # Translate Nimble's distinct operators to our universal parser
      var normalizedReq = reqVerStr
      if normalizedReq.startsWith("~="): normalizedReq = "~" & normalizedReq[2..^1]
      elif normalizedReq.startsWith("^="): normalizedReq = "^" & normalizedReq[2..^1]
      # # is used for specific commits in Nimble, which we handle via pfIsPseudo downstream
      elif normalizedReq.startsWith("#"): normalizedReq = "==" & normalizedReq[1..^1] 
      
      constr = parseConstraint(normalizedReq)

    let
      record = PackageRecord(
        nameId: symbols.getOrPut(name),
        originId: symbols.getOrPut("git"),
        urlId: urlId,
        commitId: symbols.getOrPut(""),
        srcDirId: symbols.getOrPut("src"), # Temporary, resolved when queued
        entrypointId: symbols.getOrPut(""),
        version: FaeVer(),
        flags: {pfForeignNimble}
      )
      dependencyId = registry.addPackage(record)
      constraintId = registry.addConstraint(constr)

    registry.addEdge(DependencyEdge(
      dependent: dependentId,
      dependency: dependencyId,
      constraint: constraintId
    ))
import std/[httpclient, json, os, parsejson, streams, strutils, parseutils, tables]
import faepkg/logging
import faepkg/core/[types, interner, state]
import faepkg/logic/manifest

const FaeCompatNimblePkgsUrl {.strdefine.} = "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"
var packagesJsonUpToDate = false

# The In-Memory Cache
var nimbleUrlCache = initTable[string, string]()

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

proc resolveNimbleNames*(projPath: string, pkgNames: openArray[string], logCtx: LoggerContext): Table[string, string] =
  ## Scans the cached nimblepkgs.json to find Git URLs for multiple Nimble package names.
  ## Utilizes an in-memory cache to prevent redundant disk I/O.
  
  var missingNames: seq[string] = @[]
  
  # 1. Check Cache First
  for name in pkgNames:
    let lowerName = name.toLowerAscii()
    if nimbleUrlCache.hasKey(lowerName):
      result[name] = nimbleUrlCache[lowerName]
    else:
      missingNames.add(lowerName)

  if missingNames.len == 0:
    return result

  # 2. Disk Fallback for Missing Names
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

  var
    arrayLevel = 0
    namesFound = 0
  let targetCount = missingNames.len

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
        parser.next() 
        
        if key == "name":
          currentName = parser.str().toLowerAscii()
          if currentName notin missingNames: skip = true
        elif key == "url":
          currentUrl = parser.str()
          
        if currentName != "" and currentUrl != "" and not skip:
          # Cache the result
          nimbleUrlCache[currentName] = currentUrl
          
          # Map back to the original casing requested by the user
          for orig in pkgNames:
            if orig.toLowerAscii() == currentName:
              result[orig] = currentUrl
              break
              
          inc namesFound
          skip = true
          
      # Halt the parser entirely if we found every missing dependency
      if namesFound == targetCount:
        return result

    else: discard

  # Log warnings for anything we failed to find
  for missing in missingNames:
    if not nimbleUrlCache.hasKey(missing):
      logCtx.warn("Could not resolve Nimble package name: " & missing)

  return result

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
    baseSrcDir = if man.srcDir != "": man.srcDir else: "src"
    finalSrcDir = baseSrcDir & "/" & man.packageName

  registry.packages[dependentId.uint32].srcDirId = symbols.getOrPut(finalSrcDir)
  registry.packages[dependentId.uint32].entrypointId = symbols.getOrPut("../" & man.packageName & ".nim")

  # Pre-scan required names to execute a single batched lookup
  var namesToResolve: seq[string] = @[]
  for reqStr in man.requiresData:
    var name = ""
    discard parseUntil(reqStr, name, {'#', '=', '>', '<', '^', '~', ' '})
    name = name.strip()
    if name != "" and name notin ["nim", "compiler"] and "://" notin name:
      namesToResolve.add(name)

  let resolvedUrls = if namesToResolve.len > 0: resolveNimbleNames(projPath, namesToResolve, logCtx)
                     else: initTable[string, string]()

  # Process Transitive Dependencies
  for reqStr in man.requiresData:
    var name = ""
    let idx = parseUntil(reqStr, name, {'#', '=', '>', '<', '^', '~', ' '})
    name = name.strip()
    
    if name == "" or name in ["nim", "compiler"]: continue

    var rawUrl = name
    if "://" notin rawUrl:
      if resolvedUrls.hasKey(name): rawUrl = resolvedUrls[name]

    let
      urlId = symbols.getOrPut(rawUrl)
      reqVerStr = reqStr[idx..^1].strip()
    var constr = FaeVerConstraint(lo: FaeVer(), hi: FaeVer(major: int.high))
    
    if reqVerStr.len > 0:
      var normalizedReq = reqVerStr
      if normalizedReq.startsWith("~="): normalizedReq = "~" & normalizedReq[2..^1]
      elif normalizedReq.startsWith("^="): normalizedReq = "^" & normalizedReq[2..^1]
      elif normalizedReq.startsWith("#"): normalizedReq = "==" & normalizedReq[1..^1] 
      
      constr = parseConstraint(normalizedReq)

    let
      record = PackageRecord(
        nameId: symbols.getOrPut(name),
        originId: symbols.getOrPut("git"),
        urlId: urlId,
        commitId: symbols.getOrPut(""),
        srcDirId: symbols.getOrPut("src"),
        entrypointId: symbols.getOrPut(""),
        subdirId: symbols.getOrPut(""),
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
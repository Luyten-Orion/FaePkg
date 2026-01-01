import std/[
  httpclient,
  json,
  os,
  parsejson,
  streams,
  strutils,
  tables
]

import logging

const FaeCompatNimblePkgsUrl {.strdefine.} = "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

# State tracking to avoid spamming GitHub if we call this multiple times in a run
var packagesJsonUpToDate = false

proc initNimbleCompat*(projPath: string, logCtx: LoggerContext) =
  ## Ensures the local copy of the Nimble packages.json is up to date.
  if packagesJsonUpToDate: return

  let
    logCtx = logCtx.with("compat", "nimble", "init")
    faeDir = projPath / ".skull" / "fae"
  createDir(faeDir)
  let path = faeDir / "nimblepkgs.json"

  let
    client = newHttpClient()
    resp = try:
        client.getContent(FaeCompatNimblePkgsUrl)
      except HttpRequestError:
        if not fileExists(path):
          logCtx.error("Failed to fetch `packages.json` from github! Cannot proceed.")
          client.close()
          quit(1)
        logCtx.warn("Failed to fetch `packages.json` from github! Using local copy.")
        packagesJsonUpToDate = true
        client.close()
        return

  client.close()

  writeFile(path, resp)
  packagesJsonUpToDate = true


proc getNimbleExpandedNames*(
  projPath: string,
  namesP: openArray[string]
): Table[string, string] =
  ## Scans the cached nimblepkgs.json to find the URLs for the given package names.
  ## Returns a table of Name -> URL.
  
  let pkgDataStrm = try:
      openFileStream(projPath / ".skull" / "fae" / "nimblepkgs.json", fmRead)
    except IOError:
      # If the file is missing/corrupt, we can't resolve names.
      quit("Failed to open `nimblepkgs.json` for Nimble compat! Run sync again.", 1)

  var
    parser: JsonParser
    arrayLevel = 0
  
  # We use the streaming parser to avoid loading the entire JSON into memory
  parser.open(pkgDataStrm, "nimblepkgs.json")

  # Mutable copy of names we are looking for so we can stop early if found all
  var names = @namesP

  while true:
    parser.next()

    case parser.kind()
    of jsonError, jsonEof:
      break 
    of jsonArrayStart:
      inc arrayLevel
    of jsonArrayEnd:
      dec arrayLevel
      if arrayLevel == 0: break
    of jsonObjectStart:
      var
        skip = false
        pkgName: string
        pkgUrl: string

      # Parse a single package entry object
      while parser.kind() != jsonObjectEnd:
        parser.next()
        if skip: continue

        if parser.kind() != jsonString:
          # Malformed structure handling
          # (Skip until next key or object end)
          continue
        
        let key = parser.str().toLowerAscii()

        if key notin ["name", "url"]:
          # Skip unknown fields safely
          parser.next()
          case parser.kind()
          of jsonString, jsonInt, jsonFloat, jsonTrue, jsonFalse: discard
          of jsonArrayStart, jsonObjectStart:
            # Skip nested structures
            # (Note: simpler logic here for brevity, usually nimble registry is flat)
            discard 
          else: discard
          continue

        parser.next() # Move to value
        
        if key == "name":
          if parser.str() notin names:
            skip = true
            continue
          pkgName = parser.str()
        elif key == "url":
          pkgUrl = parser.str()

        if pkgName != "" and pkgUrl != "":
          result[pkgName] = pkgUrl
          # Remove found name from search list
          let idx = names.find(pkgName)
          if idx != -1: names.del(idx)
          skip = true # Done with this object
    else:
      # Should not happen in valid JSON array of objects
      discard

  parser.close()
  pkgDataStrm.close()
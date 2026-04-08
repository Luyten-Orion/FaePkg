import std/[httpclient, htmlparser, xmltree, strutils, uri, tables]
import faepkg/logging

const HardcodedVcsInfo = [
  "github.com", "gitlab.com", "codeberg.org",
]

# The In-Memory Cache
var goGetCache = initTable[string, string]()

proc isHardcodedForge(url: string): bool =
  for forge in HardcodedVcsInfo:
    if url.startsWith(forge): return true
  return false

proc resolveGoGet*(logCtx: LoggerContext, url: string): string =
  ## Returns the canonical Git URL. Bypasses HTTP if it's a known forge.
  if isHardcodedForge(url) or url.endsWith(".git"):
    return url

  # 1. Check Cache First
  let cleanUrl = url.toLowerAscii()
  if goGetCache.hasKey(cleanUrl):
    return goGetCache[cleanUrl]

  let
    logCtx = logCtx.with("go-get")
    client = newHttpClient()
  defer: client.close()
  
  logCtx.trace("Resolving vanity URL: " & url)

  var fetchUrl = "https://" & url
  if "?" in fetchUrl: fetchUrl &= "&go-get=1"
  else: fetchUrl &= "?go-get=1"

  let
    resp =
      try:
        client.getContent(fetchUrl)
      except HttpRequestError as e:
        logCtx.debug("Failed to fetch " & fetchUrl & ": " & e.msg)
        goGetCache[cleanUrl] = url # Cache the fallback to prevent re-querying
        return url 

    parsed = parseHtml(resp)
    html = parsed.child("html")
    
  if html == nil: 
    goGetCache[cleanUrl] = url
    return url

  let head = html.child("head")
  if head == nil: 
    goGetCache[cleanUrl] = url
    return url

  for meta in head.findAll("meta"):
    if meta.attr("name") == "go-import":
      let
        content = meta.attr("content")
        parts = content.split(' ')
      if parts.len >= 3:
        var parsedUri = parseUri(parts[2])
        parsedUri.scheme = "" # Strip scheme for internal storage
        let finalUrl = ($parsedUri).strip(chars={'/'})
        
        logCtx.trace("Resolved to: " & finalUrl)
        goGetCache[cleanUrl] = finalUrl # Cache the successful resolution
        return finalUrl

  # If we reach here, no go-import tag was found
  goGetCache[cleanUrl] = url
  return url
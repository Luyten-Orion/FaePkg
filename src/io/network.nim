import std/[httpclient, htmlparser, xmltree, strutils, options, uri]
import faepkg/logging

# In the future this should be a table that maps the forges to their appropriate
# domain names, but for now... Eh.
const HardcodedVcsInfo = [
  "github.com", "gitlab.com", "codeberg.org"
]

proc isHardcodedForge(url: string): bool =
  for forge in HardcodedVcsInfo:
    if url.startsWith(forge): return true

proc resolveGoGet*(logCtx: LoggerContext, url: string): string =
  ## Returns the canonical Git URL. Bypasses HTTP if it's a known forge.
  if isHardcodedForge(url) or url.endsWith(".git"):
    return url

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
        return url # Fallback to original

    parsed = parseHtml(resp)
    html = parsed.child("html")
  if html == nil: return url

  let head = html.child("head")
  if head == nil: return url

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
        return finalUrl

  return url
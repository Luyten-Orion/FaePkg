# src/engine/pkg/io.nim
import std/[strutils, options, tables, uri, os]
import engine/pkg/[
  addressing,
  pmodels
]
import engine/[
  adapters,
  faever
]
import engine/adapters/git
import logging

proc toOriginCtx*(pkg: PackageData, logCtx: LoggerContext): OriginContext =
  OriginContext.init(pkg.diskLoc, logCtx)


proc clone*(
  pkg: PackageData,
  logCtx: LoggerContext,
) =
  let
    adapter = origins[pkg.origin]
    originCtx = pkg.toOriginCtx(logCtx)

  # TODO: Do some validation to ensure that this *is* the correct package
  if adapter.isVcs(originCtx): return

  if not adapter.clone(originCtx, $pkg.loc):
    quit("Failed to clone package `" & pkg.id & "`", 1)


proc cloneBare*(pkg: PackageData, logCtx: LoggerContext) =
  ## Clones a repository as a bare/mirror repo into the cache.
  let logCtx = logCtx.with("git", "clone-bare")
  if pkg.origin != "git":
    logCtx.with("clone-bare").error("Cannot clone bare repo for non-git package `" & pkg.id & "`")
    quit(1)
  let originCtx = pkg.toOriginCtx(logCtx)

  createDir(originCtx.targetDir.parentDir)
  let res = gitExec(logCtx, originCtx.targetDir.parentDir, [
    "clone", "--mirror", $pkg.loc, originCtx.targetDir.rsplit('/', 1)[^1]
  ])
  logCtx.trace("Output ->\n$1" % res.output)


proc installToSite*(
  pkg: PackageData, 
  destPath: string, 
  refr: string, 
  logCtx: LoggerContext
) =
  ## Clones the package from the local cache into the final destination.
  let 
    adapter = origins[pkg.origin]
    destCtx = OriginContext.init(destPath, logCtx)
    cacheUrl = pkg.diskLoc 

  if dirExists(destPath):
    if not adapter.fetch(destCtx, cacheUrl, refr):
      logCtx.warn("Failed to update package from cache: " & pkg.id)
  else:
    if not adapter.clone(destCtx, cacheUrl):
      logCtx.error("Failed to install package `" & pkg.id & "` from cache!")
      quit(1)

  if not adapter.checkout(destCtx, refr):
    logCtx.error("Failed to checkout version `" & refr & "` for " & pkg.id)
    quit(1)


proc fetch*(
  pkg: PackageData,
  logCtx: LoggerContext,
) =
  if not origins[pkg.origin].fetch(pkg.toOriginCtx(logCtx), $pkg.loc):
    quit("Failed to fetch package `" & pkg.id & "`", 1)


proc fetch*(
  pkg: PackageData,
  logCtx: LoggerContext,
  refr: string
) =
  if not origins[pkg.origin].fetch(pkg.toOriginCtx(logCtx), $pkg.loc, refr):
    quit("Failed to fetch package `" & pkg.id & "`", 1)


# TODO: Return results or raise exceptions rather than hard quitting
proc checkout*(
  pkg: PackageData,
  logCtx: LoggerContext,
  version: FaeVer
): bool =
  ## Returns true if we successfully checked out the package
  ## Returns true if the package was already checked out
  let
    adapter = origins[pkg.origin]
    originCtx = pkg.toOriginCtx(logCtx)
  
  var vstr = $version

  # Could switch this to a single `fetch` call and then use `checkout`
  if not adapter.fetch(originCtx, $pkg.loc, "v" & vstr):
    if not adapter.fetch(originCtx, $pkg.loc, vstr):
      return false
  else:
    vstr = "v" & vstr

  if not adapter.checkout(originCtx, vstr):
    return false

  return true


proc checkout*(
  pkg: PackageData,
  logCtx: LoggerContext,
  refr: string
): bool =
  ## Returns true if we successfully checked out the package.
  ## Returns true if the package was already checked out.
  let
    adapter = origins[pkg.origin]
    originCtx = pkg.toOriginCtx(logCtx)

  # We should prefer `v` prefixed versions, we have to support non-prefixed
  # versions for nimble, but if I can move that behaviour out of this code,
  # then it will be done
  #if not adapter.fetch(originCtx, $pkg.loc, refr):
  #  logCtx.error("Failed to fetch package `" & pkg.id & "`")
  #  return false
  discard adapter.fetch(originCtx, $pkg.loc, refr)

  if not adapter.checkout(originCtx, refr):
    logCtx.error("Failed to checkout package `" & pkg.id & "`")
    return false

  return true

proc pseudoversion*(
  pkg: PackageData,
  logCtx: LoggerContext,
  refr: string
): Option[tuple[ver: FaeVer, isPseudo: bool]] =
  origins[pkg.origin].pseudoversion(pkg.toOriginCtx(logCtx), refr)


proc stripPidMarkers*(pid: string): string =
  result = pid

  let idxHash = result.rfind('#')
  if idxHash >= 0:
      result = result[0..<idxHash]

  let idxAt = result.rfind('@')
  if idxAt >= 0:
      result = result[0..<idxAt]
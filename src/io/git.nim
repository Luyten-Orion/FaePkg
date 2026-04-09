import std/[osproc, strutils, options, os, streams, times, tables]
import faepkg/logging
import faepkg/core/types

proc findGit(logCtx: LoggerContext): string =
  result = findExe("git", followSymLinks = false)
  if result.len == 0:
    logCtx.error("Git binary not found in PATH.")
    quit(1)

proc gitExec*(logCtx: LoggerContext, workingDir: string, args: openArray[string]): tuple[code: int, output: string] =
  let gitBin = findGit(logCtx)
  logCtx.trace("Executing git in `" & workingDir & "` with args: " & $args)
  
  var
    prc = startProcess(gitBin, workingDir, args)
    outp = ""
  while prc.running:
    outp &= prc.outputStream.readAll()
  
  result = (prc.exitStatus.int, outp)
  prc.close()

proc cloneBare*(logCtx: LoggerContext, url: string, targetDir: string): bool =
  createDir(targetDir.parentDir)
  let res = gitExec(logCtx, targetDir.parentDir, ["clone", "--mirror", url, targetDir.extractFilename()])
  if res.code != 0:
    logCtx.debug("Git clone failed:\n" & res.output)
  res.code == 0

proc fetch*(logCtx: LoggerContext, targetDir: string): bool =
  gitExec(logCtx, targetDir, ["fetch", "--all", "--tags"]).code == 0

proc checkout*(logCtx: LoggerContext, targetDir: string, refr: string): bool =
  gitExec(logCtx, targetDir, ["checkout", refr]).code == 0

proc catFile*(logCtx: LoggerContext, targetDir: string, refr: string, filePath: string): Option[string] =
  ## Reads a file directly from a bare repo without a working tree.
  let res = gitExec(logCtx, targetDir, ["show", refr & ":" & filePath])
  if res.code == 0:
    return some(res.output)

proc lsFiles*(logCtx: LoggerContext, targetDir: string, refr: string, pattern: string): seq[string] =
  let res = gitExec(logCtx, targetDir, ["ls-tree", "-r", "--name-only", refr])
  var matches: seq[string] = @[]
  if res.code == 0:
    for line in res.output.splitLines():
      if line.endsWith(pattern): matches.add(line)
  return matches

proc resolveRef*(logCtx: LoggerContext, targetDir: string, refr: string): Option[string] =
  ## Translates a tag or branch into a specific commit hash.
  let res = gitExec(logCtx, targetDir, ["rev-parse", refr])
  if res.code == 0:
    return some(res.output.strip())
  return none(string)

proc generatePseudoversion*(logCtx: LoggerContext, targetDir: string, refr: string): Option[FaeVer] =
  ## Synthesizes a deterministic semantic version from a git commit.
  let hashRes = gitExec(logCtx, targetDir, ["rev-parse", "--short=12", refr])
  if hashRes.code != 0: 
    return none(FaeVer)
  let commitHash = hashRes.output.strip()

  let timeRes = gitExec(logCtx, targetDir, ["show", "-s", "--format=%ct", refr])
  let timestamp = if timeRes.code == 0:
      fromUnix(parseInt(timeRes.output.strip())).format("yyyyMMddhhmmss")
    else: "00000000000000"

  # We synthesize the FaeVer: v0.0.0-<timestamp>.g<hash>
  var ver = FaeVer(major: 0, minor: 0, patch: 0)
  ver.prerelease = timestamp & ".g" & commitHash
  return some(ver)

proc resolveRelativeGitUrl*(parentUrl: string, subUrl: string): string =
  if not subUrl.startsWith("."): return subUrl
  
  var parentParts = parentUrl.split('/')
  if parentParts.len > 0 and parentParts[^1].endsWith(".git"):
    parentParts[^1] = parentParts[^1][0..^5]
    
  let subParts = subUrl.split('/')
  for p in subParts:
    if p == "..":
      if parentParts.len > 3: discard parentParts.pop()
    elif p != "." and p != "":
      parentParts.add(p)
      
  result = parentParts.join("/")
  if not result.endsWith(".git"): result &= ".git"

proc getSubmodules*(logCtx: LoggerContext, targetDir: string, refr: string): seq[tuple[name, path, url: string]] =
  let res = gitExec(logCtx, targetDir, ["config", "--blob", refr & ":.gitmodules", "--list"])
  if res.code != 0: return @[]
  
  var paths = initTable[string, string]()
  var urls = initTable[string, string]()
  
  for line in res.output.splitLines():
    let parts = line.split('=', 1)
    if parts.len != 2: continue
    let key = parts[0]
    let val = parts[1]
    
    if key.startsWith("submodule."):
      let subKeyParts = key.split('.')
      if subKeyParts.len >= 3:
        let name = subKeyParts[1..^2].join(".")
        let prop = subKeyParts[^1]
        if prop == "path": paths[name] = val
        elif prop == "url": urls[name] = val
        
  for name, path in paths:
    if urls.hasKey(name):
      result.add((name, path, urls[name]))

proc setSubmoduleCacheUrl*(logCtx: LoggerContext, targetDir: string, subName: string, cachePath: string): bool =
  let res = gitExec(logCtx, targetDir, ["config", "submodule." & subName & ".url", cachePath])
  return res.code == 0

proc updateSubmoduleShallow*(logCtx: LoggerContext, targetDir: string, subPath: string): bool =
  let res = gitExec(logCtx, targetDir, ["submodule", "update", "--init", "--depth", "1", subPath])
  if res.code != 0:
    logCtx.warn("Failed to update submodule " & subPath & " in " & targetDir & ":\n" & res.output)
  return res.code == 0
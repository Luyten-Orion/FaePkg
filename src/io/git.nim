import std/[osproc, strutils, options, os, streams, times]
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
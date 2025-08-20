import std/[
  strutils,
  streams,
  options,
  osproc,
  os
]

import parsetoml
import gittyup

import ./common


# TODO: Figure out how to do this in a non-blocking way
proc gitExec(
  workingDir: string,
  args: openArray[string]
): tuple[code: int, output: string] =
  # Returns the output of the command if it fails
  let gitBin {.global.} = findExe("git")

  if gitBin.len == 0:
    raise OSError.newException:
      "Couldn't locate the git binary! Is it in path?"

  var prc = startProcess(gitBin, workingDir, args)

  # TODO: Use tasks! https://nim-works.github.io/nimskull/tasks.html
  var outp = ""

  while true:
    outp &= prc.outputStream.readAll()
    if not prc.running: break

  result = (prc.exitStatus.int, outp)

  prc.close()


proc gitCloneImpl*(ctx: OriginContext, url: string): bool =
  # returns true on success
  gitExec(ctx.targetDir.parentDir, ["clone", url]).code == 0


proc gitFetchImpl*(ctx: OriginContext, url, refr: string): bool =
  # returns true on success
  gitExec(ctx.targetDir, ["fetch", url, refr]).code == 0


proc gitResolveImpl*(ctx: OriginContext, refr: string): Option[string] =
  # returns the resolved ref on success
  let res = gitExec(ctx.targetDir, ["rev-parse", refr])

  if res.code == 0:
    some(res.output.strip)
  else:
    none(string)


proc gitCheckoutImpl*(ctx: OriginContext, refr: string): bool =
  # returns true on success
  gitExec(ctx.targetDir, ["checkout", refr]).code == 0


origins["git"] = OriginAdapter(
  cloneImpl: gitCloneImpl,
  fetchImpl: gitFetchImpl,
  resolveImpl: gitResolveImpl,
  checkoutImpl: gitCheckoutImpl
)
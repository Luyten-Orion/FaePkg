import std/[
  strutils,
  streams,
  options,
  osproc,
  times,
  os
]

import experimental/results

import parsetoml
#import gittyup

import ./common
import ../faever


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


# TODO: Handle this more elegantly
proc gitFetchRefrImpl*(ctx: OriginContext, url, refr: string): bool =
  # returns true on success
  gitExec(ctx.targetDir, ["fetch", url, refr]).code == 0


proc gitFetchTagsImpl*(ctx: OriginContext, url: string): bool =
  # returns true on success, gets all tags
  gitExec(ctx.targetDir, ["fetch", url, "--tags"]).code == 0


proc gitResolveImpl*(ctx: OriginContext, refr: string): Option[string] =
  # returns the resolved ref on success
  let res = gitExec(ctx.targetDir, ["rev-parse", refr])

  if res.code == 0:
    some(res.output.strip)
  else:
    none(string)


proc gitPseudoversionImpl*(
  ctx: OriginContext,
  refr: string
): Option[tuple[ver: FaeVer, isPseudo: bool]] =
  # Returns the pseudoversion
  var tag: FaeVer
  let commitHash = block:
    var res = gitExec(
      ctx.targetDir,
      ["describe", "--match", "v[0-9]*.[0-9]*.[0-9]*", "--abbrev=12", refr]
    )

    if res.code != 0:
      res = gitExec(
        ctx.targetDir,
        ["describe", "--match", "[0-9]*.[0-9]*.[0-9]*", "--abbrev=12", refr]
      )

    if res.code != 0:
      return none(typeof(result).T)

    let parseRes = FaeVer.parse(
      if res.output.startsWith("v"): res.output[1..^1] else: res.output
    )
    
    tag = parseRes.get(FaeVer.low())
    var parts = tag.prerelease.rsplit('-', 3)

    if parts.len < 2 or (parts[^1].len != 13 and parts[^1][0] != 'g'):
      return some((tag, false))


    tag.prerelease = parts[0]
    # This shouldn't be present anyway...
    tag.buildMetadata = ""

    # Format returned by `git describe` is usually:
    # `<tag>-<commits since tag>-g<commit hash>`
    parts[^1][1..^1]

  let commitDate = block:
    # We'll parse the unix timestamp and convert it to a date
    let res = gitExec(ctx.targetDir, ["show", "-s", "--format=%ct", refr])

    let timestamp =
      if res.code != 0:
        fromUnix(0)
      else:
        fromUnix(parseInt(res.output.strip()))

    timestamp.format("yyyyMMddhhmmss")

  if tag.prerelease.len > 0: tag.prerelease &= "."
  else: inc tag.patch
  tag.prerelease &= commitDate & "." & commitHash
  
  some((tag, true))


proc gitCheckoutImpl*(ctx: OriginContext, refr: string): bool =
  # returns true on success
  gitExec(ctx.targetDir, ["checkout", refr]).code == 0


proc gitIsVcsImpl*(ctx: OriginContext): bool =
  # returns true if the directory is a git repo
  dirExists(ctx.targetDir / ".git")


origins["git"] = OriginAdapter(
  cloneImpl: gitCloneImpl,
  fetchRefrImpl: gitFetchRefrImpl,
  fetchTagsImpl: gitFetchTagsImpl,
  resolveImpl: gitResolveImpl,
  pseudoversionImpl: gitPseudoversionImpl,
  checkoutImpl: gitCheckoutImpl,
  isVcs: gitIsVcsImpl
)
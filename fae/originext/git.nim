import std/[
  # For clean string interpolation
  strformat,
  # For string splitting (mostly on paths)
  strutils,
  # Used for converting iterators to sequences
  sequtils,
  # For passing a custom environment to the `startProcess` function
  strtabs,
  # For reading the process output
  streams,
  # For key-table mappings, such as the `repoToLoc` field
  tables,
  # For `startProcess` (cloning/fetching from git)
  osproc,
  # Anon proc generation
  sugar,
  # To avoid collisions in file names on Windows and avoid special chars in name
  sha1,
  # Used for URI handling
  uri,
  # Used for path handling
  os
]

import parsetoml
import badresults
import gittyup

import ../tomlhelpers
import ./common

#[
TODO:

  * Implement git's authorisation helpers... somehow xP
]#


type
  GitAdapter* = ref object of OriginAdapter

  GitContext* = ref object of OriginContext
    caseSensitivePath* {.rename: "case-sensitive-path", optional(false).}: bool
    uriToPath* {.ignore.}: Table[Uri, string]


proc ctx*(ga: GitAdapter): GitContext =
  assert ga.ctx != nil, "Context wasn't initialised properly!"
  assert ga.ctx of GitContext, "Context wasn't initialised properly!"

  GitContext(ga.ctx)


proc gitExec(args: openArray[string], workingDir = ""): Process =
  let
    env {.global.} = {
      # TODO: Add custom handling for the respective askpass commands
      "GIT_TERMINAL_PROMPT": "0",
      "GIT_ASKPASS": "",
      "SSH_ASKPASS_REQUIRE": "force",
      "SSH_ASKPASS": ""
    }.newStringTable
    gitBin {.global.} = findExe("git")

  if gitBin.len == 0:
    raise newException(OSError, "The `git` binary couldn't be found!")

  startProcess(gitBin, args = args, env = env, workingDir = workingDir,
    options = {poUsePath, poStdErrToStdOut})


template cloneOrFetchErrors(
  uri: Uri,
  result: var OriginFetchResult,
  output: seq[string]
) =
  if "ERROR: Repository not found." in output:
    result.err(OriginFetchErr(kind: NotFound))
    return

  elif &"git@{uri.hostname}: Permission denied (publickey)." in output:
    result.err(OriginFetchErr(kind: Unauthorised))
    return

  for i in [
    "fatal: unable to access '$1': Could not resolve host: github.com" % $uri,
    "ssh: Could not resolve hostname github.com: Temporary failure in name resolution"
  ]:
    if i in output:
      result.err(OriginFetchErr(kind: Unreachable))
      return

  result.err(OriginFetchErr(kind: Other, msg: output.join("\n")))


# TODO: Use sanitised paths based on the given URI rather than a trimmed hash
proc getDirImpl(ctx: GitContext, uri: Uri): string =
  ctx.uriToPath.mgetOrPut(
    uri, ".fae" / "deps" / ($secureHash($uri))[0..8].toLowerAscii)


proc cloneImpl(ctx: GitContext, uri: Uri): OriginFetchResult =
  # TODO: Extract this logic into `common.nim`, or maybe something higher that
  # polls each process until complete. `std/tasks` seems good for this.
  let path = ctx.getDirImpl(uri)

  if path.dirExists and toSeq(path.walkDir).len > 0:
    return OriginFetchResult.err(OriginFetchErr(kind: NonEmptyTargetDir))

  if path.fileExists:
    return OriginFetchResult.err(OriginFetchErr(kind: TargetIsFile))

  let p = gitExec(["clone", "--no-checkout", $uri, ctx.getDirImpl(uri)])
  defer: p.close

  while p.peekExitCode == -1:
    sleep(1000)

  if p.peekExitCode == 0:
    return OriginFetchResult.ok()

  let output = p.outputStream.readAll.splitLines

  cloneOrFetchErrors(uri, result, output)


proc fetchImpl(ctx: GitContext, uri: Uri): OriginFetchResult =
  let p = gitExec(["fetch", "--all"], ctx.getDirImpl(uri))
  defer: p.close

  while p.peekExitCode == -1:
    sleep(1000)

  if p.peekExitCode == 0:
    return OriginFetchResult.ok()

  let output = p.outputStream.readAll.splitLines

  cloneOrFetchErrors(uri, result, output)


proc tagsImpl(ctx: GitContext, uri: Uri): OriginTagsResult =
  let repo = block:
    let x = repositoryOpen(ctx.getDirImpl(uri))

    if x.isErr:
      return OriginTagsResult.err(x.error.dumpError)

    x.get

  let tags = block:
    let x = repo.tagList

    if x.isErr:
      return OriginTagsResult.err(x.error.dumpError)

    x.get

  return OriginTagsResult.ok(OriginTags(tags: tags))


proc checkoutImpl(ctx: GitContext, uri: Uri, tag: string): bool =
  let repo = block:
    let x = repositoryOpen(ctx.getDirImpl(uri))

    if x.isErr:
      # Failed to checkout
      return false

    x.get

  let thing = block:
    let x = repo.lookupThing(tag)

    if x.isErr:
      # Failed to checkout
      return false

    x.get

  not bool(repo.checkoutTree(thing))


# TODO: Maybe abstract away the URI directly? No real reason to expose it.
# TODO: Maybe add/remove the .git extension to the path?
proc normaliseImpl(ctx: GitContext, uri: Uri): Uri =
  result = uri
  if ctx.caseSensitivePath: result.path |= toLowerAscii


proc expandUriImpl(ctx: GitContext, uri: Uri): Uri =
  ## The only parts of the URI that we respect is the path,
  ## and maybe the query.
  # TODO: Query likely needs to be examined and processed separately,
  # for things like subdirectories...
  result = Uri(scheme: ctx.scheme, hostname: ctx.host, path: uri.path,
    query: uri.query)

  # Not sure how to handle this rn.
  if result.scheme == "ssh":
    result.username = "git"


# TODO: Maybe have a central place where this adapter is registered in a table?
proc newGitAdapter*(config: TomlValueRef): OriginAdapter =
  template gitCtx(i: OriginContext): GitContext = GitContext(i)

  result = OriginAdapterCallbacks(
    getDir: (i: OriginContext, a: Uri) => getDirImpl(gitCtx(i), a),
    clone: (i: OriginContext, a: Uri) => cloneImpl(gitCtx(i), a),
    fetch: (i: OriginContext, a: Uri) => fetchImpl(gitCtx(i), a),
    tags: (i: OriginContext, a: Uri) => tagsImpl(gitCtx(i), a),
    checkout: (i: OriginContext, a: Uri, b: string) => checkoutImpl(
      gitCtx(i), a, b
    ),
    normaliseUri: (i: OriginContext, a: Uri) => normaliseImpl(gitCtx(i), a),
    expandUri: (i: OriginContext, a: Uri) => expandUriImpl(gitCtx(i), a),
    isRemote: () => true
  ).newOriginAdapter

  result.ctx = GitContext.fromToml(config)

  if result.ctx.scheme == "": result.ctx.scheme = "https"
  else:
    if result.ctx.scheme notin ["http", "https", "ssh", "git"]:
      quit "The scheme must be either `http`, `https`, `ssh` or `git`!", 1
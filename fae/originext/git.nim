import std/[
  # For string splitting (mostly on paths)
  strutils,
  # For passing a custom environment to the `startProcess` function
  strtabs,
  # For reading the output stream of a process
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
    scheme* {.optional: "https".}: string
    caseSensitivePath* {.rename: "case-sensitive-path", optional(false).}: bool


# Maaaybe put this in common.nim? Also assuming `uri`s have been normalised.
proc uriToPath(uri: Uri): string =
  ".fae" / "deps" / ($secureHash($uri))[0..8].toLowerAscii


proc ctx*(ga: GitAdapter): GitContext =
  assert ga.ctx != nil, "Context wasn't initialised properly!"
  assert ga.ctx of GitContext, "Context wasn't initialised properly!"

  GitContext(ga.ctx)


proc gitExec(args: varargs[string], workingDir = ""): Process =
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
    options = {poStdErrToStdOut})


proc normaliseImpl(ctx: GitContext, uri: Uri): Uri =
  result = uri
  if ctx.caseSensitivePath: result.path |= toLowerAscii


template cloneOrFetchErrors(result: var OriginFetchResult, output: seq[string]) =
  if "ERROR: Repository not found." in output:
    result.err(OriginFetchErr(kind: NotFound))
    return

  elif "git@github.com: Permission denied (publickey)." in output:
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


proc cloneImpl(ctx: GitContext, uri: Uri): OriginFetchResult =
  # TODO: Extract this logic into `common.nim`, or maybe something higher that
  # polls each process until complete. `std/tasks` seems good for this.
  let p = gitExec("clone", "--no-checkout", $uri, uriToPath(uri))

  while p.peekExitCode == -1:
    sleep(1000)

  if p.peekExitCode == 0:
    return OriginFetchResult.ok()

  let output = p.outputStream.readAll.splitLines

  cloneOrFetchErrors(result, output)


proc fetchImpl(ctx: GitContext, uri: Uri): OriginFetchResult =
  let p = gitExec("fetch", "--all", workingDir = uriToPath(uri))

  while p.peekExitCode == -1:
    sleep(1000)

  if p.peekExitCode == 0:
    return OriginFetchResult.ok()

  let output = p.outputStream.readAll.splitLines

  cloneOrFetchErrors(result, output)


proc tagsImpl(ctx: GitContext, uri: Uri): OriginTagsResult =
  let repo = block:
    let x = repositoryOpen(uriToPath(uri))

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
    let x = repositoryOpen(uriToPath(uri))

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


# TODO: Maybe have a central place where this adapter is registered in a table?
proc newGitAdapter*(config: TomlValueRef): OriginAdapter =
  template gitCtx(i: OriginContext): GitContext = GitContext(i)

  result = OriginAdapterCallbacks(
    clone: (i: OriginContext, a: Uri) => cloneImpl(gitCtx(i), a),
    fetch: (i: OriginContext, a: Uri) => fetchImpl(gitCtx(i), a),
    tags: (i: OriginContext, a: Uri) => tagsImpl(gitCtx(i), a),
    checkout: (i: OriginContext, a: Uri, b: string) => checkoutImpl(
      gitCtx(i), a, b
    ),
    normaliseUri: (i: OriginContext, a: Uri) => normaliseImpl(gitCtx(i), a)
  ).newOriginAdapter

  result.ctx = GitContext.fromToml(config)
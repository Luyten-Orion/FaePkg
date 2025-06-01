import std/[
  strutils,
  sequtils,
  options,
  strtabs,
  tables,
  macros,
  osproc,
  uri,
  os
]

import parsetoml

import ./fae/[
  tomlhelpers,
  semver
]

const LatestFaeFormat* = 0

# Data types
type
  PinKind* = enum
    # TODO: Replace `Reference` with a more appropriate name
    Unset, Version, Reference

  PkgManifest* = object
    format*: uint
    metadata* {.rename: "package".}: PkgMetadata
    # ordered table so it can be serialised in the same order
    forges*: OrderedTable[string, Repository]
    dependencies*: seq[PkgDependency]

  PkgMetadata* = object
    vcs*: string
    authors*: seq[string]
    description*, license*: Option[string]
    srcDir* {.rename: "src-dir"}: Option[string]
    binDir* {.rename: "bin-dir"}: Option[string]
    bin*: seq[string]
    documentation*, source*, homepage*: Option[string]
    # For any data that isn't relevant to Fae, but exists for other tools
    ext*: TomlTable

  Repository* = object
    vcs*: string
    # TODO: Maybe remove this from design, it'll be unnecessary if we use a sane
    # default, and allow overriding via `.fae-overrides.toml`
    #protocols*: seq[string]
    host*: string

  # The name of the dependency is irrelevant to Fae, since it'll use the name
  # the repo is checked out as, unless explicitly overridden with `relocate`
  PkgDependency* = object
    # `src` uses URIs, which are then 'remapped' to the full URL, or if there
    # isn't a forge definition used, it'll use the URI as given.
    src*: Uri
    relocate*: Option[string]
    pin* {.ignore.}: PinKind
    version* {.tag("pin", Version).}: Option[SemVer]
    # Left as a string since it's interpreted by the vcs plugin
    refr* {.rename: "ref", tag("pin", Reference).}: Option[string]


proc fromTomlImpl*(
  res: var PkgDependency,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl

  tomlhelpers.fromTomlImpl(res, t, conf)

  if res.version.isSome and res.refr.isSome:
    raise newException(KeyError, "Cannot specify both `version` and `ref`!")

  if res.version.isNone and res.refr.isNone:
    raise newException(KeyError, "Must specify either `version` or `ref`!")

  if res.version.isNone:
    res.pin = Reference
  else:
    res.pin = Version


let manifest = PkgManifest.fromToml(parseFile("fae.toml"))

assert manifest.metadata.vcs == "git", "Only git repositories are supported!"

# The git stuff should likely be split into a fae-git plugin that is shipped by
# default

var
  schemes: Table[string, Uri]
  dependencies: seq[PkgDependency]

for scheme, repoInfo in manifest.forges.pairs:
  # TODO: Allow people to override this somehow... Maybe a
  # `.fae-overrides.toml` that isn't committed to a VCS? So people could use
  # an access token, for example.

  # Also, I don't like the way this is defined lmao, the protocols should likely
  # be hardcoded, rather than making ppl specify it, this also supports the impl
  # of a `.fae-overrides`, but my concern is the amount of TOML files specific
  # to Fae that people would need for stuff like a monorepo that pulls in
  # private dependencies from multiple places
  assert repoInfo.vcs == "git", "Only git repositories are supported!"

  schemes[scheme] = Uri(scheme: "https", hostname: repoInfo.host)


for mdep in manifest.dependencies:
  # TODO: Go through all subdependencies, too, this will be important when
  # trying to use MVS (Minimal Version Selection)
  var dep = mdep

  if dep.src.scheme in schemes:
    let path = dep.src.path
    dep.src = schemes[dep.src.scheme]
    dep.src.path = path

  dependencies.add dep

  echo dep

#[
var
  queued, succeded: seq[string]
  repoToLoc: Table[string, string]
  processes: Table[string, Process]


for dep in dependencies:
  var repoLoc = ".fae" / "deps" / dep.src.path.split("/")[^1]

  if repoLoc.endsWith(".git"): repoLoc = repoLoc[0..^5]

  queued.add $dep.src
  repoToLoc[$dep.src] = repoLoc


proc git(op, repo, loc: string): Process =
  let
    env {.global.} = {"GIT_TERMINAL_PROMPT": "0"}.newStringTable
    gitBin {.global.} = findExe("git")


  if op == "clone":
    startProcess(gitBin, args = [op, repo, loc], env = env)
  elif op == "fetch":
    startProcess(gitBin, loc, args = [op], env = env)
  else:
    raise newException(ValueError, "Unknown operation: " & op)


proc getOp(p: string): string =
  if p.dirExists:
    return "fetch"
  else:
    return "clone"


let count = queued.len

while succeded.len < count:
  if processes.len < 4 and queued.len > 0:
    let
      repo = queued.pop
      loc = repoToLoc[repo]
      word =
        if getOp(loc) == "clone":
          "Cloning "
        else:
          "Fetching "

    processes[repo] = git(getOp(loc), repo, loc)
    echo word, repo

  for process in toSeq(processes.keys):
    if processes[process].peekExitCode == 0:
      succeded.add process
      let word =
        if getOp(repoToLoc[process]) == "clone":
          "cloned "
        else:
          "fetched "
      echo "Successfully ", word, process
      processes[process].close()
      processes.del(process)

      if queued.len > 0:
        let
          repo = queued.pop
          loc = repoToLoc[repo]

        processes[repo] = git(getOp(loc), repo, loc)
        let word =
          if getOp(loc) == "clone":
            "Cloning "
          else:
            "Fetching "

        echo word, repo

    elif processes[process].peekExitCode == -1: continue

    else:
      let word =
        if getOp(process) == "clone":
          "clone "
        else:
          "fetch "
      echo "Failed to ", word, process, ", exited with code ",
        processes[process].peekExitCode

  sleep 1000
]#
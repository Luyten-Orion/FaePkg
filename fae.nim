import std/[
  sequtils,
  options,
  tables,
  macros
]

import parsetoml
import gittyup

import ./fae/[
  tomlhelpers,
  semver
]

const LatestFaeFormat = 0

# Data types
type
  PinKind* = enum
    # TODO: Replace `Reference` with a more appropriate name
    Unset, Version, Reference

  PkgManifest* = object
    format*: uint
    metadata* {.rename: "package".}: PkgMetadata
    # ordered table so it can be serialised in the same order
    repositories*: OrderedTable[string, Repository]
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
    protocols*: seq[string]
    host*: string

  # The name of the dependency is irrelevant to Fae, since it'll use the name
  # the repo is checked out as, unless explicitly overridden with `relocate`
  PkgDependency* = object
    # `src` follows the format `<repo>:<path>`, anything after the semicolon is
    # passed to the appropriate VCS plugin (through the repository definition).
    # so `git+ssh@github.com:user/repo` is the same as
    # `gh:user/repo`. `path` is also a valid repository which uses file paths.
    src*: string
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

echo manifest

# This stuff should likely be split into a fae-git plugin that is shipped by
# default


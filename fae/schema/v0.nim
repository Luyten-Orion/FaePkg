import std/[
  options, # Used to signify optional fields in the manifest
  tables,  # Used for key-table mappings, such as the `forges` field
  uri      # Used for the URIs used in dependency declaration
]

import parsetoml # Used for the `TomlTable` type

import ../[
  tomlhelpers, # Used for remapping fields correctly
  semver       # Used for the `SemVer` type
]

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
    replacements*: Table[Uri, PkgReplacement]

  PkgMetadata* = object
    origin*: string
    authors*: seq[string]
    description*, license*: Option[string]
    srcDir* {.rename: "src-dir"}: Option[string]
    #binDir* {.rename: "bin-dir"}: Option[string]
    #bin*: seq[string]
    documentation*, source*, homepage*: Option[string]
    # For any data that isn't relevant to Fae, but exists for other tools
    ext*: TomlTable

  Repository* = object
    origin*: string
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

  # Allows for packages to be coerced into using a different source or version
  # despite possible incompatibility
  PkgReplacement* = object
    src*: Uri
    pin* {.ignore.}: PinKind
    version* {.tag("pin", Version).}: Option[SemVer]
    refr* {.rename: "ref", tag("pin", Reference).}: Option[string]


proc validateAndSetPin(
  res: var (PkgDependency | PkgReplacement),
  allowUnset = false
) =
  template maybeRaise(e: ref Exception) =
    if not allowUnset:
      raise e

  if res.version.isSome and res.refr.isSome:
    maybeRaise newException(KeyError,
      "Cannot specify both `version` and `ref`!")

  if res.version.isNone and res.refr.isNone:
    maybeRaise newException(KeyError, "Must specify either `version` or `ref`!")
    # If this branch runs and doesn't throw, then we can leave `pin` unset
    return

  if res.version.isNone:
    res.pin = Reference
  else:
    res.pin = Version


proc fromTomlImpl*(
  res: var PkgDependency,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl

  tomlhelpers.fromTomlImpl(res, t, conf)

  res.validateAndSetPin()


proc fromTomlImpl*(
  res: var PkgReplacement,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl

  case t.kind
  of TomlValueKind.String:
    # Parse it as a URI
    res = PkgReplacement()
    tomlhelpers.fromTomlImpl(res.src, t, conf)
  of TomlValueKind.Table:
    # Parse it as a regular table
    tomlhelpers.fromTomlImpl(res, t, conf)
  else:
    assert false, "Expected the dependency replacement to either be a table" &
      " or string!"

  res.validateAndSetPin(true)

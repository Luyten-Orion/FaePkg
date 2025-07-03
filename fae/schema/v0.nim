import std/[
  strutils, # To normalise the forge scheme declaration
  options,  # Used to signify optional fields in the manifest
  tables,   # Used for key-table mappings, such as the `forges` field
  uri       # Used for the URIs used in dependency declaration
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
    forges*: OrderedTable[string, Forge]
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

  Forge* = object
    origin*: string
    host*: Option[string]
    config*: Option[TomlValueRef]

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


proc fromTomlImpl*(
  res: var OrderedTable[string, Forge],
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  assert t.kind == TomlValueKind.Table

  for key, value in t.getTable:
    let nKey = key.toLowerAscii

    res[nKey] = Forge()
    res[nKey].fromTomlImpl(value, conf)


proc validateAndSetPin(
  res: var (PkgDependency | PkgReplacement),
  allowUnset = false
) =
  template maybeRaise(e: ref Exception) =
    if not allowUnset:
      raise e

  if res.version.isNone and res.refr.isNone:
    maybeRaise newException(KeyError, "Must specify the `version` and " &
    "the `ref` if needed!")
    # If this branch runs and doesn't throw, then we can leave `pin` unset
    return

  if res.version.isNone:
    maybeRaise newException(KeyError, "Must specify `version`! This is used " &
      "dependency resolution!")

  if res.refr.isSome:
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

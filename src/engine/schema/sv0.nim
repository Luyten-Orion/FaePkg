import std/[
  strutils,
  options,
  tables,
  uri
]

import parsetoml

import ../faever
import ../private/tomlhelpers

type
  ForgeExpansion* = object
    origin*, scheme*, host*: string

  ManifestV0* = object
    format*: Natural
    package*: PackageV0
    dependencies*: Table[string, DependencyV0]
    # Need to figure out how to do features
    #features*: seq[FeatureV0]

  PackageV0* = object
    authors*: seq[string] # Optional
    description*, license*, documentation*, source*, homepage*: Option[string]
    ext*: TomlValue # Optional metadata

  DependencyV0* = object
    src*: Uri # Required
    # Dependency origin, whether it's from git or what
    origin* {.optional: "".}: string
    # Use a better name pls
    constr* {.rename: "version".}: FaeVerConstraint # required
    refr*: Option[string]
    isNimble* {.rename: "nimble", optional: false.}: bool


const
  ForgeAliases = {
    "gh": ForgeExpansion(origin: "git", scheme: "https", host: "github.com"),
    "gl": ForgeExpansion(origin: "git", scheme: "https", host: "gitlab.com"),
    "cb": ForgeExpansion(origin: "git", scheme: "https", host: "codeberg.org")
  }.toTable


proc fromTomlImpl*(
  res: var DependencyV0,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl

  assert t.kind == TomlValueKind.Table
  tomlhelpers.fromTomlImpl(res, t, conf)

  if res.src.scheme == "":
    quit("Dependency has no scheme: " & $res.src, 1)

  if res.src.scheme in ForgeAliases:
    let alias = ForgeAliases[res.src.scheme]
    # Can't remember the default value lel
    res.src.opaque = not res.src.opaque
    res.src.scheme = alias.scheme
    res.src.hostname = alias.host
    res.origin = alias.origin
    return

  if res.origin == "":
    var parts = res.src.scheme.split('+', 1)
    
    if parts.len == 1:
      quit("Dependency has no origin: " & $res.src, 1)

    res.origin = parts.pop()
    res.src.scheme = parts.join("+")
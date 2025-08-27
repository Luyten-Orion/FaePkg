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
  PkgMngrKind* = enum
    pmNimble = "nimble"

  ManifestV0* = object
    format*: Natural
    package*: PackageV0
    metadata*: TomlTable
    dependencies*: Table[string, DependencyV0]
    # Need to figure out how to do features
    #features*: seq[FeatureV0]

  PackageV0* = object
    name*: string

  DependencyV0* = object
    src*: string # Required
    # Subdir, not provided by users
    # Scheme, this can be detected automatically but for unknown
    # forges, this makes life better, since the `src` field acts as an ID
    scheme*: string
    # Dependency origin, whether it's from git or what
    origin*: string
    subdir* {.optional: "".}: string
    # Use a better name pls
    constr* {.rename: "version".}: FaeVerConstraint # required
    refr*: Option[string]
    foreignPkgMngr* {.rename: "foreign-pm".}: Option[PkgMngrKind]
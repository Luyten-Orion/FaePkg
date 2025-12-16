import std/[
  strutils,
  options,
  tables,
  uri
]

import parsetoml

import engine/faever
import engine/private/tomlhelpers

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
    # Discouraged. Ideally use the `src` directory by default
    srcDir* {.rename: "src-dir", optional: "src".}: string

  DependencyV0* = object
    src*: string # Required
    scheme*: string
    # Dependency origin, whether it's from git or what
    origin*: string
    subdir* {.optional: "".}: string
    # Use a better name pls
    constr* {.rename: "version".}: Option[FaeVerConstraint]
    refr*: Option[string]
    foreignPkgMngr* {.rename: "foreign-pm".}: Option[PkgMngrKind]
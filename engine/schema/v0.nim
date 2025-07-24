import std/[
  options
]

import parsetoml

import ../private/tomlhelpers

type
  ManifestV0* = object
    format*: Natural
    package*: PackageV0
    forges*: seq[ForgeV0]
    sourcesets*: seq[SourceSetV0]
    dependencies*: seq[DependencyV0]
    # Need to figure out how to do features
    #features*: seq[FeatureV0]

  PackageV0* = object
    origin*: string # Required
    authors*: seq[string] # Optional
    description*, license*, documentation*, source*, homepage*: Option[string]

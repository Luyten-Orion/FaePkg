import std/[
  # Self-explanatory
  options,
  # URIs are a pretty essential part of our code
  uri
]

import parsetoml
import gram

import ./semver

type
  PackageKind* {.pure.} = enum
    pRoot, pDependency

  PackageResolutionMethodKind* {.pure.} = enum
    # Enforced would be for packages using a commit, for example.
    # The pseudoversion would be enforced, and incompatibilities will be warned.
    # Flexible means that as long as the base version is compatible with a newer
    # version, the package version can be 'upgraded'.
    prmEnforced, prmFlexible

  GraphPackage* = object
    name*: string
    kind*: PackageKind
    resolutionMethodKind*: PackageResolutionMethodKind
    # A list of versions that are compatible with the currently selected
    # version, this is used to quickly upgrade the selected version as well as
    # to check if the version requested by a package is available.
    versions*: seq[SemVer]
    # The version currently selected.
    selectedVersion*: SemVer
    # If this is `some`, then this is what will be used when checking out the
    # package, regardless of which version is selected.
    refr*: Option[string]

  GraphRelation* = object
    # The version of the dependency the dependent is compatible with.
    requires*: SemVer

  PkgGraph* = Graph[GraphPackage, GraphRelation, {UniqueNodes, Directed}]


proc newPkgGraph*(): PkgGraph {.inline.} =
  type T = PkgGraph
  result = newGraph[T.N, T.E](T.F)
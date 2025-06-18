import std/[
  # For string splitting (mostly on paths)
  strutils,
  # For converting iterators to seqs, preventing errors on when a table's keys
  # are modified during iteration
  sequtils,
  # Used to signify an optional field in the manifest
  options,
  # For key-table mappings, such as the `forges` field
  tables,
  # Used for URI handling
  uri
]

# Used for `parseFile` specifically
import parsetoml
# For building a dependency graph
import gram

import ./fae/[
  tomlhelpers,
  semver
]

import ./fae/schema/[
  v0 # First version of Fae's schema.
]

import fae/originext/[
  common,
  git
]


#[
TODO:

  * Expand all URIs *before* they reach the origin adapters!
]#



const LatestFaeFormat* = 0


let manifest = PkgManifest.fromToml(parseFile("fae.toml"))

assert manifest.metadata.origin == "git", "Only git repositories are supported!"

# The git stuff should likely be split into a fae-git plugin that is shipped by
# default

var
  schemes: Table[string, Uri]
  dependencies: seq[PkgDependency]
  adapters: Table[string, OriginAdapter]

for scheme, forge in manifest.forges.pairs:
  # TODO: Allow people to override this somehow... Maybe a
  # `.fae-overrides.toml` that isn't committed to a VCS? So people could use
  # an access token, for example.

  # TODO: Implement the replacement stage where the `replacements` from the
  # manifest are first performed, and then the overrides from the overrides file
  assert forge.origin == "git", "Only git repositories are supported!"

  adapters[scheme] = block:
    if forge.config.isSome:
      newGitAdapter(forge.config.unsafeGet)
    else:
      newGitAdapter(newTTable())

  adapters[scheme].ctx.host = forge.host

  # TODO: Have plugins provide a 'default scheme' and also use the scheme
  # defined in the manifest/overrides.
  schemes[scheme] = adapters[scheme].normaliseUri(
    Uri(scheme: "https", hostname: forge.host)
  )


for mdep in manifest.dependencies:
  # TODO: Go through all subdependencies, too, this will be important when
  # trying to use MVS (Minimal Version Selection)
  # TODO: Dep normalisation
  var dep = mdep

  if dep.src.scheme in schemes:
    let path = dep.src.path
    dep.src = schemes[dep.src.scheme]
    dep.src.path = path

  dependencies.add dep

  echo dep

#[
type
  PkgNode = object
    id*: string
    versions*: seq[string]
    # clv = current lowest version
    clv*: SemVer

  PkgEdge = void

  PkgGraph = Graph[PkgNode, PkgEdge, {UniqueNodes, Directed}]


proc newPkgGraph(): PkgGraph {.inline.} =
  type T = PkgGraph
  result = newGraph[T.N, T.E](T.F)

var depGraph = newPkgGraph()
]#


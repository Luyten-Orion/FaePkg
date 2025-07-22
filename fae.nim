import std/[
  # For clean string interpolation
  strformat,
  # For string splitting (mostly on paths)
  strutils,
  # For converting iterators to seqs, preventing errors on when a table's keys
  # are modified during iteration
  sequtils,
  # Used to signify an optional field in the manifest
  options,
  # For key-table mappings, such as the `forges` field
  tables,
  # Cleaner piping
  sugar,
  # Used for URI handling
  uri,
  # Used for removing dirs or files
  os
]

# Needed for executing the correct logic on fail or success
import badresults
# Used for `parseFile` specifically
import parsetoml
# For building a dependency graph
import gram

import ./fae/[
  tomlhelpers,
  semver,
  core
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

  * Implement a logging library and have graceful error handling.
]#



const LatestFaeFormat* = 0


type
  FaeState* = ref object
    graph*: PkgGraph
    root*: Node[GraphPackage, GraphRelation]
    # `gh` -> `https://github.com`, for example
    #schemeUriMap*: Table[string, Uri]
    # For traversing the dependencies in each dependency...
    dependencies*: seq[PkgDependency]
    adapters*: Table[string, OriginAdapter]


proc new*(T: typedesc[FaeState]): T =
  T(
    graph: newPkgGraph(),
    root: nil,
    #schemeUriMap: newTable[string, Uri](),
    adapters: newTable[string, OriginAdapter]()
  )


proc register(s: FaeState, scheme: string, a: OriginAdapter): OriginAdapter =
  result = a

  if scheme in s.adapters and s.adapters[scheme] != a:
    # TODO: Figure out how the fuck to handle this??? Likely not an issue if we
    # provide forge definitions for the most widely known ones, but still...
    quit "The scheme `" & scheme &
      "` is already registered with a different config!", 1

  s.adapters[scheme] = result


proc adapter(s: FaeState, scheme: string): OriginAdapter =
  if scheme notin s.adapters:
    quit "The scheme `" & scheme & "` is not registered!", 1

  s.adapters[scheme]


proc schemes(s: FaeState): seq[string] = toSeq(s.adapters.keys)


let manifest = PkgManifest.fromToml(parseFile("fae.toml"))

# Have an `OriginRegistry` perhaps, for registering the relevant adapter to vcs
assert manifest.metadata.origin == "git", "Only git forges are supported!"


proc processManifest(s: FaeState, manifest: PkgManifest) =
  for scheme, forge in manifest.forges.pairs:
    assert forge.origin == "git", "Only git forges are supported!"

    let adapter = s.register(
      scheme, newGitAdapter(forge.config.get(newTTable())))
    
    if adapter.isRemote:
      if forge.host.isNone:
        quit "The `host` must be declared in the manifest for this origin!", 1
      adapter.ctx.host = forge.host.unsafeGet


# TODO: Probably should remove the mutability of the dependencies
proc processDep*(s: FaeState, dep: var PkgDependency, a: OriginAdapter) =
  if dep.src.scheme notin s.schemes:
    quit "The scheme `" & dep.src.scheme & "` is not registered!", 1

  if dep.src.scheme notin s.schemes:
    quit "The scheme `" & dep.src.scheme & "` is not supported!", 1

  dep.src = a.expandUri(dep.src)



for mdep in manifest.dependencies:
  # TODO: Go through all subdependencies, too, this will be important when
  # trying to use MVS (Minimal Version Selection)
  # TODO: Dep normalisation
  var dep = mdep

  if dep.src.scheme in schemes:
    let path = dep.src.path
    dep.src = schemes[dep.src.scheme]
    dep.src.path = path

  uriToScheme[dep.src] = mdep.src.scheme
  dependencies.add dep


proc addDependency*(
  # Graph
  g: var PkgGraph,
  # Approriate origin adapter
  a: OriginAdapter,
  # Parent node
  p: Node[g.N, g.E],
  # The dependency being added in question.
  d: PkgDependency
): Node[g.N, g.E] =
  template findNodeInGraph(
    gName: string,
    graph: var PkgGraph
  ): (bool, Node[g.N, g.E]) =
    var
      res: bool
      target: Node[g.N, g.E]

    for n in graph.nodes:
      if n.value.name == gName:
        res = true
        target = n
        break

    (res, target)

  let depName = $a.normaliseUri(d.src)
  var (depRegistered, node) = findNodeInGraph(depName, g)

  if not depRegistered:
    case d.pin
    of PinKind.Version:
      let tags = block:
        let
          depVer = d.version.unsafeGet
          tagsRes = a.tags(d.src)

        if tagsRes.isErr:
          echo "Failed to fetch tags!"
          quit "Cannot proceed: " & $tagsRes.error, 1

        var ptags: seq[SemVer]
        
        for tag in tagsRes.unsafeGet.tags:
          ptags.add:
            try:
              if tag.startsWith("v"): SemVer.parse(tag[1..^1])
              else: SemVer.parse(tag)
            # TODO: Maybe report the issue... Not sure
            except ValueError: continue

        ptags.filter((ver: SemVer) => ver >=~ depVer)

      # TODO: Maybe... Do this better?
      node = g.add GraphPackage(
        name: depName,
        kind: pDependency,
        resolutionMethodKind: prmFlexible,
        versions: tags,
        selectedVersion: d.version.unsafeGet,
        refr: d.refr
      )

    else:
      quit "References aren't supported yet!", 1

  discard g.edge(p, GraphRelation(requires: d.version.unsafeGet), node)

  return node


proc processDependencies*(
  g: var PkgGraph,
  root: Node[g.N, g.E]
) =
  var
    tbl: OrderedTable[Node[g.N, g.E], seq[Edge[g.N, g.E]]]
    nodes = @[root]

  while nodes.len > 0:
    let n = nodes.pop

    for edge, target in n.outgoing:
      nodes.add target

      discard tbl.hasKeyOrPut(target, @[])
      tbl[target].add edge

  for k, v in tbl.pairs:
    echo "============"
    echo k.value
    echo "---values---"
    for i in v:
      echo i.value
    echo "============"



var depGraph = newPkgGraph()


var rootNode = depGraph.add GraphPackage(
  name: "root",
  kind: pRoot,
  resolutionMethodKind: prmEnforced,
  # TODO: Utility to grab the current version easily
  # also maybe some sort of way to detect if the package is being developed
  # locally or not?
  selectedVersion: SemVer.parse("0.0.0"),
  # TODO: Get the appropriate reference string
  refr: none(string)
)

# TODO: Maybe extract the logic into a function 
for dep in dependencies:
  let scheme = uriToScheme[dep.src]

  # TODO: Don't constantly clone, idk how to check for this tho
  #[
  block handleCloneErr:
    var res = adapters[scheme].clone(dep.src)

    if res.isOk: break handleCloneErr

    let
      err = res.error
      loc = adapters[scheme].getDir(dep.src)

    if err.kind in {NotFound, TimedOut, Unreachable, Unauthorised}:
      quit "Cannot proceed: " & $err, 1
    elif err.kind in {NonEmptyTargetDir, TargetIsFile}:
      echo "Warning: the target is either a non-empty dir or a file! Removing."

      try:
        if err.kind == NonEmptyTargetDir:
          removeDir(loc)
        elif err.kind == TargetIsFile:
          removeFile(loc)
      except OSError as e:
        quit "Failed to remove target: " & e.msg, 1

      echo "Trying to clone again..."
      res = adapters[scheme].clone(dep.src)

      if res.isErr:
        echo "Failed again!"
        quit "Cannot proceed: " & $res.error, 1

    else:
      echo err
      quit "Unhandled error!", 1
  ]#

  # Fetch logic
  block fetchLogic:
    let res = adapters[scheme].fetch(dep.src)

    if res.isErr:
      echo "Failed to fetch!"
      quit "Cannot proceed: " & $res.error, 1


  if dep.pin != PinKind.Version:
    quit "Version is required! References aren't supported yet!", 1

  # TODO: URI to node mapping? Might be unnecessary though.
  discard depGraph.addDependency(adapters[scheme], rootNode, dep)


depGraph.processDependencies(rootNode)
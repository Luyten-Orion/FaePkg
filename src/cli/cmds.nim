import std/[
  sequtils,
  strutils,
  tables,
  uri,
  os
]

import parsetoml

import ../engine/private/tomlhelpers
import ../engine/[resolution, adapters, faever, schema]

type
  FaeCmdKind* = enum
    fkNone, fkGrab

  FaeArgs* = object
    skullPath*: string
    projPath*: string
    case kind*: FaeCmdKind
    of fkNone:
      discard
    of fkGrab:
      discard

  # TODO: Type needs to be moved into the engine code
  RepoSrc* = object
    # Maybe store ID in this?
    # Adapter
    origin*: string
    # Full URL (scheme included)
    loc*: Uri
    # Disk location
    diskLoc*: string


# TODO: Move to engine
proc getSource(dep: DependencyV0, diskLoc = ""): RepoSrc =
  RepoSrc(loc: dep.src, origin: dep.origin, diskLoc: diskLoc)
 

# This doubles as the directory name of the dep, so we need to escape any
# special characters on the common OSes
proc toId*(src: RepoSrc): string =
  var u = src.loc
  u.scheme = ""

  # I'm tired pls don't judge me
  for c in $u:
    if c == '!':
      result.add("!!")
    elif c == '_':
      result.add("!_")
    elif c.isUpperAscii:
      result.add('!')
      result.add(c.toLowerAscii)
    else:
      result.add(c)


proc ensureDepDir(args: FaeArgs, d: string): string =
  try:
    # TODO: Move these two to something earlier
    discard existsOrCreateDir(args.projPath / ".fae")
    discard existsOrCreateDir(args.projPath / ".fae" / "deps")
    
    let dirParts = d.split('/')
    var currDir = args.projPath / ".fae" / "deps"
    for p in dirParts:
      currDir = currDir / p
      if not dirExists(currDir):
        createDir(currDir)

    result = args.projPath / ".fae" / "deps" / d.split('/').join($DirSep)
  except OSError as e:
    quit("Failed to create dependency directory: " & e.msg, 1)


proc registerDep(
  pkgMap: var Table[string, RepoSrc],
  g: DependencyGraph,
  fromId: string,
  m: ManifestV0,
  d: DependencyV0
) =
  # TODO: Figure out a more plugganle way to do this? Since workspaces may have
  # the source on disk in a different location that .fae/deps/[...]
  let
    nSrc = getSource(d)
    id = nSrc.toId

  pkgMap[id] = nSrc
  g.add(id)
  try:
    g.link(toId = id, fromId = fromId,
      constr = d.constr)
  except ValueError:
    quit("Failed to parse constraint `" & $d.constr & "`!", 1)


template parseManifest(a: FaeArgs, f: string): ManifestV0 =
  var res: ManifestV0
  let file = f
  try:
    res = ManifestV0.fromToml(parseFile(file))
  except IOError:
    quit("No fae.toml found in `" & file.parentDir & "`, not a Fae project!", 1)
  except TomlError as e:
    quit("Failed to parse the package manifest: " & e.msg, 1)
  res


# TODO: We should also warn users if there are dependencies that seem identical
# with different casing, since if that's the case, they *may* be the same...
proc grabCmd*(args: FaeArgs) =
  var 
    packages: Table[string, ManifestV0]
    pkgMap: Table[string, RepoSrc]
    g = newGraph(@["root"])
    changed = true

  if not dirExists(args.projPath):
    quit("Not a valid directory!", 1)

  # Just initial set up
  packages["root"] = args.parseManifest(args.projPath / "skullproj.toml")

  for dep in packages["root"].dependencies.values:
    pkgMap.registerDep(g, "root", packages["root"], dep)

  # Vive la resolution!
  while changed:
    changed = false

    let conflicts =
      try: g.resolve()
      except KeyError as e: quit("Graph resolution failed: " & e.msg, 1)

    if conflicts.len > 0:
      # TODO: Pretty print conflict table
      quit("Dependency resolution failed with conflicts!\n" & $conflicts, 1)

    let reachable = g.collectReachable()

    for x in reachable:
      if changed: break
      changed = x.changed

    for dep in reachable:
      if dep.id notin pkgMap:
        quit("Missing source info for dependency: " & dep.id, 1)

      let repo = pkgMap[dep.id]

      if repo.origin.len == 0:
        quit("Dependency `" & dep.id & "` has no origin", 1)
      if repo.origin notin origins:
        quit("No adapter registered for origin `" & repo.origin & "`", 1)

      let
        adapter = origins[repo.origin]
        depPath = ensureDepDir(args, dep.id)
        ctx = OriginContext(targetDir: depPath)
        vtag = "v" & $dep.constraint.lo

      if not dirExists(depPath / ".git"):
        if not adapter.clone(ctx, $repo.loc):
          quit("Failed to fetch dependency from " & $repo.loc, 1)

      if not adapter.fetch(ctx, $repo.loc, vtag):
        quit("Failed to fetch version $1 of $2" % [vtag, dep.id], 1)

      if not adapter.checkout(ctx, vtag):
        quit("Failed to checkout version $1 of $2" % [vtag, dep.id], 1)

      if dirExists(args.projPath / ".fae" / "deps" / dep.id):
        let manifest = args.parseManifest(ctx.targetDir / "skullproj.toml")
        packages[dep.id] = manifest

        for mdep in manifest.dependencies.values:
          pkgMap.registerDep(g, dep.id, manifest, mdep)
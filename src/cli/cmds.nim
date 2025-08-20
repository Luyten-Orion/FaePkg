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
    # Adapter
    origin*: string
    # Config
    config*: TomlTable
    # Full URL (scheme included)
    loc*: Uri
    # Disk location
    diskLoc*: string


# TODO: Move to engine
proc expandSrcUri(uri: Uri, forges: Table[string, ForgeV0]): RepoSrc =
  let forge = block:
    var f: seq[ForgeV0]

    for fg in forges.keys:
      if fg == uri.scheme:
        f.add(forges[fg])

    f

  if forge.len < 1:
    quit("Expected one forge with the alias `" & uri.scheme & "`", 1)

  elif forge.len > 1:
    quit("Expected only one forge with the alias `" & uri.scheme & "`", 1)

  RepoSrc(
    # TODO: This shouldn't be here! Also this is written shittily! Do better!!
    loc: Uri(scheme: forge[0].config["protocol"].getStr,
      hostname: forge[0].config["host"].getStr, path: uri.path),
    origin: forge[0].origin,
  )
 

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


proc registerDep(
  pkgMap: var Table[string, RepoSrc],
  g: DependencyGraph,
  fromId: string,
  m: ManifestV0,
  d: DependencyV0
): string =
  let nSrc = expandSrcUri(d.src, m.forges)
  result = nSrc.toId

  pkgMap[result] = nSrc
  g.add(result)
  try:
    g.link(toId = result, fromId = fromId,
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
    queue = @["root"]
    changed = true

  if not dirExists(args.projPath):
    quit("Not a valid directory!", 1)

  # Just initial set up
  packages["root"] = args.parseManifest(args.projPath / "fae.toml")

  for dep in packages["root"].dependencies:
    queue.add pkgMap.registerDep(g, "root", packages["root"], dep)

  # Vive la resolution!
  while changed:
    changed = false

    while queue.len > 0:
      let depId = queue.pop()
      if depId in packages: continue


      if depId notin pkgMap:
        quit("No source found for dependency `" & depId & "`!", 1)

      let repo = pkgMap[depId]

      if repo.origin.len == 0:
        quit("Dependency `" & depId & "` has no origin", 1)
      if repo.origin notin origins:
        quit("No adapter registered for origin `" & repo.origin & "`", 1)

      let
        adapter = origins[repo.origin]
        ctx = OriginContext(config: repo.config,
          targetDir: args.projPath / ".fae" / "deps" / depId)

      try:
        discard existsOrCreateDir(args.projPath / ".fae")
        discard existsOrCreateDir(args.projPath / ".fae" / "deps")
        
        let dirParts = depId.split(DirSep)
        var currDir = args.projPath / ".fae" / "deps"
        for p in dirParts:
          currDir = currDir / p
          if not dirExists(currDir):
            createDir(currDir)
      except OSError as e:
        quit("Failed to create dependency directory: " & e.msg, 1)

      if not dirExists(args.projPath / ".fae" / "deps" / depId / ".git"):
        if not adapter.clone(ctx, $repo.loc):
          quit("Failed to fetch dependency from " & $repo.loc, 1)

    # TODO: This has to be done repeatedly until the resolve function doesn't
    # detect any further changes
    let conflicts =
      try: g.resolve()
      except KeyError as e: quit("Graph resolution failed: " & e.msg, 1)

    if conflicts.len > 0:
      # TODO: Pretty print conflict table
      quit("Dependency resolution failed with conflicts!\n" & $conflicts, 1)

    let reachable = g.collectReachable()
    
    echo reachable

    # Maybe just do this in a regular loop so we can break out early
    changed = reachable.mapIt(it.changed).foldl(a or b, false)

    for dep in reachable:
      if dep.id notin pkgMap:
        quit("Missing source info for dependency: " & dep.id, 1)

      let
        repo = pkgMap[dep.id]
        adapter = origins[repo.origin]
        ctx = OriginContext(config: repo.config,
          targetDir: args.projPath / ".fae" / "deps" / dep.id)
        vtag = "v" & $dep.constraint.lo

      if not adapter.fetch(ctx, $repo.loc, vtag):
        quit("Failed to fetch version $1 of $2" %
          [vtag, dep.id], 1)

      if not adapter.checkout(ctx, vtag):
        quit("Failed to checkout version $1 of $2" %
          [vtag, dep.id], 1)

      if dirExists(args.projPath / ".fae" / "deps" / dep.id):
        let manifest = args.parseManifest(ctx.targetDir / "fae.toml")
        packages[dep.id] = manifest

        for mdep in manifest.dependencies:
          queue.add pkgMap.registerDep(g, dep.id, manifest, mdep)

      queue.add dep.id
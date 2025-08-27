import std/[
  sequtils,
  strutils,
  tables,
  uri,
  os
]

import parsetoml

import ../[
  resolution,
  adapters,
  schema,
  faever
]
import ./shared


proc grab*(projPath: string) =
  var 
    packages: Table[string, ManifestV0]
    pkgMap: Table[string, PackageData]
    g = newGraph()
    changed = true

  if not dirExists(projPath):
    quit("Not a valid directory!", 1)

  if not fileExists(projPath / "package.skull.toml"):
    quit("No `package.skull.toml` found! Not a valid Fae project!", 1)

  # Set up root package
  let root = block:
    let m = parseManifest(projPath / "package.skull.toml")
    pkgMap[m.package.name] = m.toPkgData
    pkgMap[m.package.name].diskLoc = projPath
    packages[m.package.name] = m
    g.add(m.package.name)

    for dep in m.dependencies.values:
      let pkgData = dep.toPkgData
      pkgMap.registerDep(g, m.package.name, m, pkgData, dep.constr)

    m.package.name


  while changed:
    changed = false

    let conflicts =
      try: g.resolve(root)
      except KeyError as e: quit("Graph resolution failed: " & e.msg, 1)

    if conflicts.len > 0:
      quit("Dependency resolution failed with conflicts!\n" & $conflicts, 1)

    let reachable = g.collectReachable(root)

    for x in reachable:
      if changed: break
      changed = x.changed

    for dep in reachable:
      if dep.id notin pkgMap:
        quit("Missing source info for dependency: " & dep.id, 1)

      template pkg: var PackageData = pkgMap[dep.id]

      # TODO: We only need to do this once per dependency, since
      # the source doesn't change mid-resolution
      if pkg.origin.len == 0:
        quit("Dependency `" & dep.id & "` has no origin", 1)
      if pkg.origin notin origins:
        quit("No adapter registered for origin `" & pkg.origin & "`", 1)

      # TODO: Look into sparse checkouts, right now we clone an entire monorepo
      # to disk for a single dependency...
      if pkg.diskLoc == "":
        pkg.diskLoc = (projPath / ".skull" / "packages" / pkg.getFolderName)
        ensureDirExists(pkg.diskLoc)

      let
        adapter = origins[pkg.origin]
        ctx = OriginContext(targetDir: pkg.diskLoc)
        vtag = "v" & $dep.constraint.lo

      # TODO: Don't hardcode git, since we plan to support other sources
      if not dirExists(ctx.targetDir / ".git"):
        if not adapter.clone(ctx, $pkg.loc):
          quit("Failed to fetch dependency from " & $pkg.loc, 1)

      if not adapter.fetch(ctx, $pkg.loc, vtag):
        quit("Failed to fetch version $1 of $2" % [vtag, dep.id], 1)

      if not adapter.checkout(ctx, vtag):
        quit("Failed to checkout version $1 of $2" % [vtag, dep.id], 1)

      if dirExists(ctx.targetDir):
        let manifest = parseManifest:
          [ctx.targetDir, pkg.subdir, "package.skull.toml"]
            .filterIt(not it.isEmptyOrWhitespace)
            .join($DirSep)

        packages[dep.id] = manifest
        for mdep in manifest.dependencies.values:
          pkgMap.registerDep(
            g, dep.id, manifest,
            pkgMap.mgetOrPut(mdep.toId, mdep.toPkgData()), mdep.constr
          )
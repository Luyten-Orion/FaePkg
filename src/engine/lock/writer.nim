import std/[
  options,
  strutils,
  tables,
  algorithm,
  uri,
  macros
]
import parsetoml
import experimental/results

import logging
import engine/faever
import engine/lock/lv0
import engine/private/tomlhelpers
import engine/processes/contexts
import engine/pkg/[io, addressing, pmodels]
import engine/adapters


proc fromSyncCtx*(ctx: SyncProcessCtx, logCtx: LoggerContext): LockFile =
  ## Generates a lockfile from a SyncProcessCtx
  let logCtx = logCtx.with("lockfile-generator")
  result = LockFile(format: LockFileVersion, dependencies: @[])

  for pid, pkg in ctx.packages:
    if pid == ctx.rootPkgId: continue

    let adapter = origins[pkg.data.origin]
    let originCtx = pkg.data.toOriginCtx(logCtx)
    
    let commit = adapter.resolveImpl(originCtx, pkg.refr).get("")

    var src: string
    if ctx.sourceMap.hasKey(pid):
      let unresPkg = ctx.sourceMap[pid]
      let uri = unresPkg.data.loc
      # Remake the uri without identifying user info
      src = uri.scheme & "://" & uri.hostname & (if uri.port.len > 0: ":" & uri.port else: "") & uri.path
    else:
      # Shouldn't happen ever, but if it does... :shrug:
      logCtx.warn("Could not find source for package: " & pid)

    var dep = LockDependency(
      name: pkg.data.id.stripPidMarkers(),
      commit: commit,
      origin: pkg.data.origin,
      src: src,
      srcDir: pkg.data.srcDir,
      subDir: pkg.data.subdir,
      entrypoint: pkg.data.entrypoint
    )
    if pkg.refr.len > 0:
      dep.refr = some(pkg.refr)
    else:
      dep.version = some(pkg.constr.lo)

    result.dependencies.add(dep)
  
  result.dependencies.sort(proc(a, b: LockDependency): int = cmp(a.name, b.name))
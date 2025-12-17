import std/[
  strutils,
  tables,
  random,
  os
]

import engine/resolution
import engine/processes/shared

randomize()


type
  SyncProcessCtx* = ref object
    projPath*, tmpDir*, rootPkgId*: string
    graph*: DependencyGraph
    # ID -> Package (The resolved state)
    packages*: Packages
    # Dependent ID -> Dependencies (The queue for the *next* cycle)
    unresolved*: Table[string, seq[UnresolvedPackage]]
    # Resolved PID -> The UnresolvedPackage (Source data cache)
    sourceMap*: Table[string, UnresolvedPackage]

  # Package -> Path
  IndexedPackage* = object
    path*: string
    srcDir*: string
    entrypoint*: string

  # Dependent -> Dependencies (Dependency IDX in packages and namespave declared by dependent)
  DependencyLink* = object
    pkgIdx*: int
    namespace*: string

  FaeIndex* = object
    packages*: seq[IndexedPackage]
    depends*: Table[string, seq[DependencyLink]]

const ValidChars = Letters + Digits

proc randomSuffix*(inPath: string): string =
  var randStr = newStringOfCap(8)
  for i in 0..<8:
    randStr.add(ValidChars.sample())

  if inPath.endsWith(DirSep):
    # Trim last char off
    return inPath[0..^2] & "_" & randStr

  return inPath & randStr
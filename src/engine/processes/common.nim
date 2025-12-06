import std/[
  strutils,
  tables,
  random,
  os
]

import ../resolution
import ./shared

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

const ValidChars = Letters + Digits

proc randomSuffix*(inPath: string): string =
  var randStr = newStringOfCap(8)
  for i in 0..<8:
    randStr.add(ValidChars.sample())

  if inPath.endsWith(DirSep):
    # Trim last char off
    return inPath[0..^2] & "_" & randStr

  return inPath & randStr
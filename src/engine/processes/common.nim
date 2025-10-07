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
    # ID -> Package
    packages*: Packages
    # Queue of packages that need to be resolved first before
    # anything else... Needed for pseudoversion support and Nimble compat
    # Dependent ID -> Dependencies
    unresolved*: Table[string, seq[UnresolvedPackage]]

const ValidChars = Letters + Digits

proc randomSuffix*(inPath: string): string =
  var randStr = newStringOfCap(8)
  for i in 0..<8:
    randStr.add(ValidChars.sample())

  if inPath.endsWith(DirSep):
    # Trim last char off
    return inPath[0..^2] & "_" & randStr

  return inPath & randStr
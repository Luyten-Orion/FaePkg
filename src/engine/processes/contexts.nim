import std/tables
import engine/pkg/pmodels
import engine/resolution

type
  SyncProcessCtx* = ref object
    projPath*, tmpDir*, rootPkgId*: string
    graph*: DependencyGraph
    packages*: Packages
    unresolved*: Table[string, seq[UnresolvedPackage]]
    sourceMap*: Table[string, UnresolvedPackage]
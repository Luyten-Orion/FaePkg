import std/tables
import faepkg/engine/pkg/pmodels
import faepkg/engine/resolution

type
  SyncProcessCtx* = ref object
    projPath*, tmpDir*, rootPkgId*: string
    graph*: DependencyGraph
    packages*: Packages
    unresolved*: Table[string, seq[UnresolvedPackage]]
    sourceMap*: Table[string, UnresolvedPackage]
import experimental/results

import std/[
  sequtils,
  tables,
  sets
]

import ../logging
import ./[schema, faever]


type
  MergeInfo* = object
    edges*: seq[DependencyEdge]
    constr*: FaeVerConstraint

  DependencyEdge* = object
    ## Dependency Edge
    id*: string
    constr*: FaeVerConstraint

  NarrowedConstraint* = object
    dependencyId*: string
    constr*: FaeVerConstraint

  DependencyConflict* = object
    # The conflicting edges.
    mergedEdges*: seq[DependencyEdge]
    conflictingEdge*: DependencyEdge

  Conflicts* = seq[DependencyConflict]
  ResolveResult* = Result[seq[NarrowedConstraint], Conflicts]

  DependencyGraph* = ref object
    # Dependent ID -> Dependency Edge (Dependency ID <-> Constraint)
    edges*: Table[string, seq[DependencyEdge]]


proc link*(
  g: DependencyGraph,
  dependentId, dependencyId: string,
  constr: FaeVerConstraint
) {.inline.} =
  g.edges.mgetOrPut(dependentId, @[]).add DependencyEdge(
    id: dependencyId,
    constr: constr
  )


proc unlinkAllDepsOf*(
  g: DependencyGraph,
  dependent: string
) {.inline.} =
  g.edges.del(dependent)


proc resolve*(
  g: DependencyGraph
): ResolveResult =
  var
    conflicts: Conflicts
    merges: Table[string, MergeInfo]

  for dependentId, dependencies in g.edges:
    for dependency in dependencies:
      var tmpConstr =
        if merges.hasKey(dependency.id):
          merges[dependency.id].constr
        else:
          FaeVerConstraint(lo: FaeVer.low, hi: FaeVer.high)

      tmpConstr = merge(tmpConstr, dependency.constr)

      if not tmpConstr.isSatisfiable:
        assert merges.hasKey(dependency.id), "We shouldn't be *able* to get here"
        conflicts.add DependencyConflict(
          mergedEdges: merges[dependency.id].edges,
          conflictingEdge: dependency
        )

      else:
        if not merges.hasKey(dependency.id):
          merges[dependency.id] = MergeInfo(
            edges: @[],
            constr: dependency.constr
          )

        merges[dependency.id].edges.add dependency

  if conflicts.len > 0: return ResolveResult.err(conflicts)
  ResolveResult.ok(toSeq(merges.pairs)
    .filterIt(it[1].edges.len > 1)
    .mapIt(NarrowedConstraint(
      dependencyId: it[0],
      constr: it[1].constr
    ))
  )
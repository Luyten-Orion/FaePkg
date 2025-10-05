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
    dependentId*: string      ## The dependent ID.
    dependencyId*: string     ## The dependency ID.
    constr*: FaeVerConstraint ## The constraint on the dependency.

  # Why not make this return a `FaeVer` rather than a `FaeVerConstraint`?
  NarrowedConstraint* = object
    id*: string               ## The ID of the package.
    constr*: FaeVerConstraint ## The constraint on the package that we resolved.

  DependencyConflictSource* = object
    dependentId*: string      ## The dependent causing a conflict.
    constr*: FaeVerConstraint ## The constraint that caused the conflict.

  DependencyConflict* = object
    # Returns the information related to a conflict.
    dependencyId*: string
    successes*: seq[DependencyConflictSource]
    conflicting*: DependencyConflictSource

  Conflicts* = seq[DependencyConflict]
  ResolveResult* = Result[seq[NarrowedConstraint], Conflicts]

  DependencyGraph* = ref object
    # Dependent ID -> Dependency Edge (Dependency ID <-> Constraint)
    edges*: OrderedTable[string, seq[DependencyEdge]]


proc link*(
  g: DependencyGraph,
  dependentId, dependencyId: string,
  constr: FaeVerConstraint
) =
  # This is... Excessive. And we could replace it with a table instead
  var dupIdxs: seq[int]

  for idx, edge in g.edges.mgetOrPut(dependentId, @[]):
    if edge.dependencyId == dependencyId:
      dupIdxs.add idx

  if dupIdxs.len > 0:
    for i in 0..<(dupIdxs.len div 2):
      swap(dupIdxs[i], dupIdxs[dupIdxs.high - i])

    for idx in dupIdxs:
      g.edges[dependentId].del(idx)

  g.edges[dependentId].add DependencyEdge(
    dependentId: dependentId,
    dependencyId: dependencyId,
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

  for dependentId, edges in g.edges:
    for edge in edges:
      var tmpConstr =
        if merges.hasKey(edge.dependencyId):
          merges[edge.dependencyId].constr
        else:
          FaeVerConstraint(lo: FaeVer.low, hi: FaeVer.high)

      tmpConstr = merge(tmpConstr, edge.constr)

      if not tmpConstr.isSatisfiable:
        assert merges.hasKey(edge.dependencyId), "We shouldn't be *able* to get here!"
        conflicts.add DependencyConflict(
          dependencyId: edge.dependencyId,
          successes: merges[edge.dependencyId].edges
            .mapIt(DependencyConflictSource(
              dependentId: it.dependentId,
              constr: it.constr
            )
          ),
          conflicting: DependencyConflictSource(
            dependentId: edge.dependentId,
            constr: edge.constr
          )
        )

      else:
        if not merges.hasKey(edge.dependencyId):
          merges[edge.dependencyId] = MergeInfo(
            edges: @[],
            constr: edge.constr
          )
        else:
          merges[edge.dependencyId].constr = tmpConstr

        merges[edge.dependencyId].edges.add edge

  if conflicts.len > 0: return ResolveResult.err(conflicts)
  ResolveResult.ok(toSeq(merges.pairs)
    .mapIt(NarrowedConstraint(
      id: it[0],
      constr: it[1].constr
    ))
  )
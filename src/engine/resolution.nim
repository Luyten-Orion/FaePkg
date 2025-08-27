import experimental/results

import std/[
  sequtils,
  tables,
  sets
]

import ./[schema, faever]

type
  WorkingDependency* = object
    # Should probably figure this out tbh, not sure what the ID should be...
    # could just use the expanded URL as the ID
    id*: string
    # The constraint the dependency has been narrowed to, so far
    constraint*: FaeVerConstraint

  DependencyRelation* = object
    id*: string
    constraint*: FaeVerConstraint

  ConflictSource* = object
    dependent*: string
    rel*: DependencyRelation

  DependencyConflict* = object
    constraintToSatisfy*: FaeVerConstraint
    sources*: seq[ConflictSource]

  ConflictTable* = Table[string, DependencyConflict]
  ResolveResult* = Result[void, ConflictTable]

  DependencyGraph* = ref object
    deps*: Table[string, WorkingDependency]
    tbl*: Table[string, seq[DependencyRelation]]


proc newGraph*(deps = newSeq[string]()): DependencyGraph =
  result = DependencyGraph()
  for dep in deps: result.deps[dep] = WorkingDependency(id: dep)


proc add*(g: DependencyGraph, id: string) {.inline.} =
  if id in g.deps: return
  g.deps[id] = WorkingDependency(id: id)


proc link*(
  g: DependencyGraph,
  toId, fromId: string,
  constr: FaeVerConstraint
) {.inline.} =
  g.tbl.mgetOrPut(toId, @[]).add:
    DependencyRelation(id: fromId, constraint: constr)


proc unlinkAll*(
  g: DependencyGraph,
  id: string
) {.inline.} =
  g.tbl.del(id)


proc resolve*(
  g: DependencyGraph,
  root: string
): ResolveResult =
  var
    toMerge: Table[string, seq[ConflictSource]]
    visited: HashSet[string]
    # `root` is the project dir or workspace that Fae is executed from
    stack = @[root]

  while stack.len > 0:
    let id = stack.pop()

    visited.incl id

    for depId, dependents in g.tbl:
      for rel in dependents:
        if rel.id == id:
          if depId notin g.deps:
            raise KeyError.newException("Unknown dependency: " & depId)
          if depId notin visited:
            stack.add depId
          toMerge.mgetOrPut(depId, @[]).add:
            ConflictSource(dependent: id, rel: rel)


  var
    resolved: Table[string, DependencyRelation]
    conflicts: ConflictTable

  for id, deps in toMerge:
    let rootDep = deps.filterIt(it.dependent == root)

    block mergeConstraints:
      if rootDep.len != 1: break mergeConstraints

      resolved[id] = rootDep[0].rel
      assert resolved[id].constraint.isSatisfiable, $resolved[id]

    for dep in deps:
      if dep.dependent == root: continue

      if not resolved.hasKey(id):
        resolved[id] = dep.rel
        continue

      let newConstr = merge(resolved[id].constraint, dep.rel.constraint)

      if not newConstr.isSatisfiable:
        if id notin conflicts:
          conflicts[id] = DependencyConflict(
            constraintToSatisfy: resolved[id].constraint, sources: @[])
        conflicts[id].sources.add dep
        continue

      resolved[id].constraint = newConstr

  if conflicts.len > 0: return ResolveResult.err(conflicts)

  for id, rel in resolved:
    if id notin g.deps: raise KeyError.newException("Unknown dependency: " & id)
    if g.deps[id].constraint == rel.constraint: continue
    g.deps[id].constraint = rel.constraint

  ResolveResult.ok()
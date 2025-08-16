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

  DependencyGraph* = ref object
    deps*: Table[string, WorkingDependency]
    tbl*: Table[string, seq[DependencyRelation]]


  Engine = object
    graph*: DependencyGraph
    queue*: seq[Event]

  EventKind* = enum
    eInvalid, eResolve, eFetch, eProcess, eComplete

  Event* = object
    case kind*: EventKind
    of eInvalid, eResolve, eComplete: discard
    of eFetch: toFetch*: seq[WorkingDependency]
    of eProcess: toProcess*: seq[ManifestV0]


proc initGraph*(deps: seq[WorkingDependency]): DependencyGraph =
  result = DependencyGraph()
  for dep in deps: result.deps[dep.id] = dep


proc link*(
  g: DependencyGraph,
  toId, fromId: string,
  constr: FaeVerConstraint
) {.inline.} =
  g.tbl.mgetOrPut(toId, @[]).add:
    DependencyRelation(id: fromId, constraint: constr)


proc resolve*(
  g: DependencyGraph
# The existence of this type should be sufficient proof to be used as evidence
# that I deserve a death sentence...
): ConflictTable =
  var
    toMerge: Table[string, seq[ConflictSource]]
    visited: HashSet[string]
    # `root` is the project dir or workspace that Fae is executed from
    stack = @["root"]

  while stack.len > 0:
    let id = stack.pop()

    visited.incl id

    if id notin g.tbl: continue
    for dep in g.tbl[id]:
      if dep.id notin g.deps: return
      if dep.id notin visited: stack.add dep.id
      toMerge.mgetOrPut(dep.id, @[]).add ConflictSource(dependent: id, rel: dep)


  var resolved: Table[string, DependencyRelation]


  for id, deps in toMerge:
    let rootDep = deps.filterIt(it.dependent == "root")

    block mergeConstraints:
      if rootDep.len != 1: break mergeConstraints

      resolved[id] = rootDep[0].rel
      assert resolved[id].constraint.isSatisfiable, $resolved[id]

    for dep in deps:
      if dep.dependent == "root": continue

      if not resolved.hasKey(id):
        resolved[id] = dep.rel
        continue

      let newConstr = merge(resolved[id].constraint, dep.r.constraint)

      if not newConstr.isSatisfiable:
        if id notin result:
          result[id] = DependencyConflict(
            constraintToSatisfy: resolved[id].constraint, sources: @[])
        result[id].sources.add ConflictSource(dependent: dep.src, rel: dep.r)
        continue

      resolved[id].constraint = newConstr


  for id, rel in resolved:
    if id notin g.deps: raise KeyError.newException("Unknown dependency: " & id)
    g.deps[id].constraint = rel.constraint


proc collectReachable*(g: DependencyGraph): seq[WorkingDependency] =
  var
    visited: HashSet[string]
    stack = @["root"]

  while stack.len > 0:
    let id = stack.pop()
    if id in visited: continue
    visited.incl id

    if id notin g.tbl: continue
    for dep in g.tbl[id]:
      stack.add dep.id

  for id in visited:
    if id == "root": continue
    if id in g.deps:
      result.add g.deps[id]


iterator next*(e: var Engine): Event =
  while e.queue.len > 0:
    let ev = e.queue.pop

    if ev.kind == eResolve:
      e.graph.resolve()

  yield Event(kind: eComplete)
import std/[
  sequtils,
  options,
  tables,
  sets
]

import ./faever

import ./adapters

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

  DependencyGraph* = ref object
    deps*: Table[string, WorkingDependency]
    tbl*: OrderedTable[string, seq[DependencyRelation]]


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
): Table[string,
  tuple[constraintToSatisfy: FaeVerConstraint, sq: seq[
    tuple[src: string, r: DependencyRelation]
    ]]
  ] =
  var
    toMerge: OrderedTable[string, seq[tuple[r: DependencyRelation, src: string]]]
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
      toMerge.mgetOrPut(dep.id, @[]).add (dep, id)


  var resolved: OrderedTable[string, DependencyRelation]


  for id, deps in toMerge:
    let rootDep = deps.filterIt(it.src == "root")

    block mergeConstraints:
      if rootDep.len != 1: break mergeConstraints

      resolved[id] = rootDep[0].r
      assert resolved[id].constraint.isSatisfiable, $resolved[id]

    for dep in deps:
      if dep.src == "root": continue

      if not resolved.hasKey(id):
        resolved[id] = dep.r
        continue

      let newConstr = merge(resolved[id].constraint, dep.r.constraint)

      if not newConstr.isSatisfiable:
        if id notin result: result[id] = (resolved[id].constraint, @[])
        result[id].sq.add (dep.src, dep.r)
        continue

      resolved[id].constraint = newConstr


  for id, rel in resolved:
    if id notin g.deps: raise KeyError.newException("Unknown dependency: " & id)
    g.deps[id].constraint = rel.constraint
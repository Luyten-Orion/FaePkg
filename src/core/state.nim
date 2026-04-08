import faepkg/core/types

type
  RegistryState* = object
    packages*: seq[PackageRecord]
    edges*: seq[DependencyEdge]
    constraints*: seq[FaeVerConstraint]

proc initRegistryState*(): RegistryState =
  RegistryState(
    packages: newSeq[PackageRecord](),
    edges: newSeq[DependencyEdge](),
    constraints: newSeq[FaeVerConstraint]()
  )

proc addPackage*(rs: var RegistryState, pkg: PackageRecord): PackageId =
  result = PackageId(rs.packages.len.uint32)
  rs.packages.add(pkg)

proc addConstraint*(rs: var RegistryState, c: FaeVerConstraint): ConstraintId =
  result = ConstraintId(rs.constraints.len.uint32)
  rs.constraints.add(c)

proc addEdge*(rs: var RegistryState, edge: DependencyEdge) =
  rs.edges.add(edge)
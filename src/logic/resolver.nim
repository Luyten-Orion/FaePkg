import std/tables
import faepkg/core/[types, state]

# --- Pure Version Arithmetic ---

proc cmpPrel(x, y: string): int =
  if x == y: return 0
  if x == "": return 1
  if y == "": return -1
  return cmp(x, y)

proc cmp*(x, y: FaeVer): int =
  if x.major != y.major: return cmp(x.major, y.major)
  if x.minor != y.minor: return cmp(x.minor, y.minor)
  if x.patch != y.patch: return cmp(x.patch, y.patch)
  return cmpPrel(x.prerelease, y.prerelease)

template `==`*(x, y: FaeVer): bool = cmp(x, y) == 0
template `<`*(x, y: FaeVer): bool = cmp(x, y) < 0
template `<=`*(x, y: FaeVer): bool = cmp(x, y) <= 0

proc max(a, b: FaeVer): FaeVer = (if a < b: b else: a)
proc min(a, b: FaeVer): FaeVer = (if a < b: a else: b)

proc isSatisfiable*(c: FaeVerConstraint): bool =
  c.lo < c.hi or (c.lo == c.hi and c.lo notin c.excl)

# RENAMED to avoid shadowing std/tables.merge
proc mergeConstraints*(a, b: FaeVerConstraint): FaeVerConstraint =
  result.lo = max(a.lo, b.lo)
  result.hi = min(a.hi, b.hi)
  result.excl = a.excl
  for e in b.excl:
    if e notin result.excl: result.excl.add(e)

# --- Graph Resolution ---

type
  ResolveResult* = object
    success*: bool
    resolved*: seq[ResolvedPackage]
    conflicts*: seq[StringId]

proc resolveGraph*(registry: RegistryState): ResolveResult =
  var narrowed = initTable[StringId, FaeVerConstraint]()
  var conflicts: seq[StringId] = @[]
  var canonicalPkg = initTable[StringId, PackageId]()

  # 1. ESTABLISH ABSOLUTE TRUTHS & CANONICAL NODES
  for i, pkg in registry.packages:
    let pid = PackageId(i.uint32)
    
    # Track the best authoritative instance of a URL
    if not canonicalPkg.hasKey(pkg.urlId):
      canonicalPkg[pkg.urlId] = pid
    elif pfLocked in pkg.flags or pfIsPseudo in pkg.flags:
      canonicalPkg[pkg.urlId] = pid

    if pfLocked in pkg.flags:
      narrowed[pkg.urlId] = FaeVerConstraint(lo: pkg.version, hi: pkg.version)

  # 2. EDGE NARROWING (Grouped by URL)
  for edge in registry.edges:
    let targetUrlId = registry.packages[edge.dependency.uint32].urlId
    let edgeConstr = registry.constraints[edge.constraint.uint32]

    if not narrowed.hasKey(targetUrlId):
      narrowed[targetUrlId] = edgeConstr
    else:
      # Use the renamed function here
      let merged = mergeConstraints(narrowed[targetUrlId], edgeConstr)
      if not merged.isSatisfiable(): 
        if targetUrlId notin conflicts: conflicts.add(targetUrlId)
      narrowed[targetUrlId] = merged

  if conflicts.len > 0:
    return ResolveResult(success: false, resolved: @[], conflicts: conflicts)

  # 3. EMIT ONLY UNIQUE PACKAGES
  var resolved: seq[ResolvedPackage] = @[]
  for urlId, constr in narrowed:
    let canonId = canonicalPkg[urlId]
    let record = registry.packages[canonId.uint32]
    resolved.add(ResolvedPackage(
      id: canonId,
      version: constr.lo,
      commitId: record.commitId 
    ))

  return ResolveResult(success: true, resolved: resolved, conflicts: @[])
type
  # Strong IDs to prevent cross-contamination
  StringId* = distinct uint32
  PackageId* = distinct uint32
  ConstraintId* = distinct uint32

  # Semantic Versioning Types (Stripped down for DOD)
  FaeVer* = object
    major*, minor*, patch*: int
    prerelease*, buildMetadata*: string

  FaeVerConstraint* = object
    lo*, hi*: FaeVer
    excl*: seq[FaeVer]

  # Flat Data Structures (Struct of Arrays / Array of Structs)
  PackageFlags* = enum
    pfIsRoot
    pfIsPseudo
    pfForeignNimble
    pfLocked

  PackageRecord* = object
    nameId*: StringId
    originId*: StringId
    urlId*: StringId
    commitId*: StringId
    srcDirId*: StringId
    entrypointId*: StringId
    subdirId*: StringId
    version*: FaeVer
    flags*: set[PackageFlags]

  DependencyEdge* = object
    dependent*: PackageId
    dependency*: PackageId
    constraint*: ConstraintId

  ResolvedPackage* = object
    id*: PackageId
    version*: FaeVer
    commitId*: StringId


proc `==`*(x, y: StringId): bool {.borrow.}
proc `==`*(x, y: PackageId): bool {.borrow.}
proc `==`*(x, y: ConstraintId): bool {.borrow.}
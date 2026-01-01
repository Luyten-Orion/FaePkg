import std/[uri, tables, options]
import pkg/parsetoml
import engine/[
  faever,
  schema
]

type
  PackageData* = object
    origin*: string
    id*: string
    loc*: Uri
    srcDir*: string
    subdir*: string
    diskLoc*: string
    foreignPm*: Option[PkgMngrKind] # You'll need to make sure PkgMngrKind is accessible
    entrypoint*: Option[string]

  Package* = object
    data*: PackageData
    constr*: FaeVerConstraint
    refr*: string
    isPseudo*: bool

  UnresolvedPackage* = object
    data*: PackageData
    constr*: Option[FaeVerConstraint]
    refr*: Option[string]
    foreignPm*: Option[PkgMngrKind]
  
  Packages* = Table[string, Package]

  # Dependent -> Dependencies
  DependencyLink* = object
    package*: string
    namespace*: string

  # Flattened info for the index
  IndexedPackage* = object
    path*: string
    srcDir*: string
    entrypoint*: string
    dependencies*: seq[DependencyLink]

  FaeIndex* = object
    packages*: Table[string, IndexedPackage]
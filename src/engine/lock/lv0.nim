import std/[
  options
]

import ../faever

const LockFileVersion* = 0

type
  LockFile* = object
    format*: Natural
    dependencies*: seq[LockDependency]

  LockDependency* = object
    name*: string
    # The data needed to check out the dependency, for git repos, the commit
    commit*: string
    # The dependency origin
    origin*: string
    # The expanded URL the dependency expands to.
    src*: string
    # The version the dependency has currently been resolved to
    version*: FaeVer
    # The ref that the version points to, if supplied by the user
    refr*: Option[string]
    # The directory on disk (relative to the root of the manifest)
    dir*: Option[string]
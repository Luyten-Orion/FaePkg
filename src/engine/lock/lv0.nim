import std/[
  options
]

import engine/faever
import engine/private/tomlhelpers

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
    version*: Option[FaeVer]
    # The ref that the version points to, if supplied by the user
    refr*: Option[string]
    subDir* {.rename: "sub-dir".}: string
    srcDir* {.rename: "src-dir".}: string
    entrypoint*: Option[string]
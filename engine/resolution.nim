import std/[
  options
]

import ./faever

type
  WorkingDependency* = object
    # Should probably figure this out tbh, not sure what the ID should be...
    # could just use the expanded URL as the ID
    id*: string
    # The version the dependency has currently been resolved to
    version*: FaeVer
    # The commit that the version points to, if supplied by the user
    refr*: Option[string]
    # The origin (as the key for which adapter to use) and
    # full URL of the dependency
    origin*, url*: string


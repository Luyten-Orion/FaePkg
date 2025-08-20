import std/[
  options,
  tables,
  uri
]

import parsetoml

import ../faever
import ../private/tomlhelpers

type
  ManifestV0* = object
    format*: Natural
    package*: PackageV0
    forges*: Table[string, ForgeV0]
    dependencies*: seq[DependencyV0]
    # Need to figure out how to do features
    #features*: seq[FeatureV0]

  PackageV0* = object
    origin*: string # Required
    authors*: seq[string] # Optional
    description*, license*, documentation*, source*, homepage*: Option[string]
    ext*: TomlValue # Optional metadata

  ForgeV0* = object
    origin*: string # Required
    # Optional, but if a 'host' field exists in the TOML, it's moved into here
    # same story with the protocol field.
    config*: TomlTable

  DependencyV0* = object
    src*: Uri # Required
    # Use a better name pls
    constr* {.rename: "version".}: FaeVerConstraint # required
    refr*: Option[string]


proc fromTomlImpl*(
  res: var ForgeV0,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  assert t.kind == TomlValueKind.Table  

  var host, protocol: Option[string]

  if t.hasKey("host"):
    host.fromTomlImpl(t["host"], conf)
    t.delete("host")

  if t.hasKey("protocol"):
    protocol.fromTomlImpl(t["protocol"], conf)
    t.delete("protocol")

  tomlhelpers.fromTomlImpl(res, t, conf)

  if host.isSome: res.config["host"] = newTString(host.unsafeGet)
  if protocol.isSome: res.config["protocol"] = newTString(protocol.unsafeGet)
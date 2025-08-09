# TODO: Fae's commandline interface
import engine/[
  faever,
  schema,
  lock,
  resolution
]
import engine/adapters/[common, git]
import engine/private/tomlhelpers

import parsetoml

let
  manifest = ManifestV0.fromToml(parseFile("fae.toml"))


echo $manifest
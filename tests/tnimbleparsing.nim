import std/[
  sequtils,
  options,
  tables,
  os
]

import src/engine/foreign/nimble
import src/engine/faever


block: # just test if it can grab the srcDir and the various requires
  let manifest = parseNimble("tests/tnimbleparsing/dummy.nimble")

  const tests = block:
    var deps: seq[string]

    for i in 'A'..'Z': deps.add "dummy" & $i

    deps

  assert manifest.srcDir == "src"
  assert manifest.requiresData == tests


block:
  let manifest = parseNimble("tests/tnimbleparsing/standard.nimble")

  var deps = manifest.requiresData
    .map(requireToDep)
    .mapIt((it.name, it.version)).toTable

  for dep in deps:
    echo dep


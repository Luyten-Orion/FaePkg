import std/[
  sequtils,
  options,
  tables,
  os
]

import experimental/results

import src/engine/foreign/nimble
import src/engine/faever
import src/logging

let tmpDir = block:
  let res = getTempDir()
  assert res.dirExists(), "Can't proceed since there's no temp dir!"
  discard existsOrCreateDir(res / "faepkg-test")
  res / "faepkg-test"

initNimbleCompat(tmpDir)

block: # just test if it can grab the srcDir and the various requires
  let manifest = parseNimble("tests/tnimbleparsing/dummy.nimble")

  const tests = block:
    var deps: seq[string]

    for i in 'A'..'Z': deps.add "dummy" & $i

    deps

  assert manifest.srcDir == "src"
  assert manifest.requiresData == tests


block:
  echo getNimbleExpandedNames(tmpDir, ["repo1", "repo2"])


block:
  #[ TODO: Check this
requires "https://github.com/Luyten-Orion/FaeNimbleCompatA>1.0.0" # Allowed but lowerbound must be set elsewhere
requires "repo2<1.0.0" # Allowed but lowerbound must be set elsewhere
requires "repo1 >= 1.0.0" # Allowed
requires "repo2 <= 1.0.0" # Allowed but lowerbound must be set elsewhere
requires "repo1 == 1.0.0" # Allowed
requires "repo2 >= 1.0.0 < 2.0.0" # Allowed
requires "repo1 > 1.0.0 < 2.0.0" # Allowed but lowerbound must be set elsewhere
  ]#
  let
    logger = Logger.new()
    logCtx = logger.with("tnimbleparsing")
    manifest = parseNimble("tests/tnimbleparsing/standard.nimble")

  var deps = manifest.requiresData
    .mapIt(requireToDep(logCtx, it))

  template fv(s: string): FaeVer = FaeVer.parse(s).unsafeGet

  assert deps[0].decl.constr.unsafeGet == FaeVerConstraint(lo: fv"1.0.0",
    hi: FaeVer.high, excl: @[fv"1.0.0"])
  assert deps[1].decl.constr.unsafeGet == FaeVerConstraint(lo: FaeVer(), hi: fv"1.0.0", excl: @[fv"1.0.0"])
  assert deps[2].decl.constr.unsafeGet == FaeVerConstraint(lo: fv"1.0.0", hi: FaeVer.high)
  assert deps[3].decl.constr.unsafeGet == FaeVerConstraint(lo: FaeVer(), hi: fv"1.0.0")
  assert deps[4].decl.constr.unsafeGet == FaeVerConstraint(lo: fv"1.0.0", hi: fv"1.0.0")
  assert deps[5].decl.constr.unsafeGet == FaeVerConstraint(lo: fv"1.0.0", hi: fv"2.0.0", excl: @[fv"2.0.0"])
  assert deps[6].decl.constr.unsafeGet == FaeVerConstraint(lo: fv"1.0.0", hi: fv"2.0.0", excl: @[fv"1.0.0", fv"2.0.0"])
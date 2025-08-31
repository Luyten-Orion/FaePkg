import std/options

import experimental/results

import src/engine/faever

# Maybe add this to `fae/faever`?
template fv(s: string): FaeVer = FaeVer.parse(s).unsafeGet

# TODO: Set up more tests, for greater than *and* compatible
assert fv"0.9.9" < fv"1.0.0"
assert fv"0.9.0" < fv"0.10.0"
assert fv"1.0.0-alpha" < fv"1.0.0-alpha.1"
assert fv"1.0.0-beta" < fv"1.0.0-beta.2"
assert fv"1.0.0-beta.2" < fv"1.0.0-beta.11"
assert fv"1.0.0-beta.11" < fv"1.0.0-rc.1"
assert fv"1.0.0-rc" < fv"1.0.0-unstable"
assert fv"1.0.0-rc.1" < fv"1.0.0"

assert fv"1.0.0" == fv"1.0.0+a"

# Testing the version constraint parsing and validation
template fvc(s: string): FaeVerConstraint = FaeVerConstraint.parse(s)

block:
  let v = fv"1.2.3"
  assert fvc"==1.2.3" == FaeVerConstraint(lo: v, hi: v, excl: @[])

block:
  let
    v = fv"1.2.3"
    vMj = v.nextMajor
  assert fvc"^1.2.3" == FaeVerConstraint(lo: v, hi: vMj, excl: @[vMj])

block:
  let
    v = fv"1.2.3"
    vMn = v.nextMinor
  assert fvc"~1.2.3" == FaeVerConstraint(lo: v, hi: vMn, excl: @[vMn])

block:
  let
    vl = fv"1.2.3"
    vh = fv"2.3.4"
    c = fvc"==1.2.3,==2.3.4"
  assert c == FaeVerConstraint(lo: vh, hi: vl, excl: @[])
  assert not c.isSatisfiable
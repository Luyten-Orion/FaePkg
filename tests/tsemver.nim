import fae/semver

# Maybe add this to `fae/semver`?
template sv(s: string): SemVer = SemVer.parse(s)

# TODO: Set up more tests, for greater than *and* compatible
assert sv"0.9.9" < sv"1.0.0"
assert sv"0.9.0" < sv"0.10.0"
assert sv"1.0.0-0.0" < sv"1.0.0-0.0.0"
assert sv"1.0.0-9999" < sv"1.0.0--"
assert sv"1.0.0-99" < sv "1.0.0-100"
assert sv"1.0.0-alpha" < sv"1.0.0-alpha.1"
assert sv"1.0.0-alpha.1" < sv"1.0.0-alpha.beta"
assert sv"1.0.0-alpha.beta" < sv"1.0.0-beta"
assert sv"1.0.0-beta" < sv"1.0.0-beta.2"
assert sv"1.0.0-beta.2" < sv"1.0.0-beta.11"
assert sv"1.0.0-beta.11" < sv"1.0.0-rc.1"
assert sv"1.0.0-rc.1" < sv"1.0.0"
assert sv"1.0.0-0" < sv"1.0.0--1"
assert sv"1.0.0-0" < sv"1.0.0-1"
assert sv"1.0.0-1.0" < sv"1.0.0-1.-1"

assert sv"1.0.0" == sv"1.0.0+a"
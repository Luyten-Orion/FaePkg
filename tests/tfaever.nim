import faever

# Maybe add this to `fae/faever`?
template sv(s: string): FaeVer = FaeVer.parse(s)

# TODO: Set up more tests, for greater than *and* compatible
assert sv"0.9.9" < sv"1.0.0"
assert sv"0.9.0" < sv"0.10.0"
assert sv"1.0.0-alpha" < sv"1.0.0-alpha.1"
assert sv"1.0.0-beta" < sv"1.0.0-beta.2"
assert sv"1.0.0-beta.2" < sv"1.0.0-beta.11"
assert sv"1.0.0-beta.11" < sv"1.0.0-rc.1"
assert sv"1.0.0-rc.1" < sv"1.0.0"

assert sv"1.0.0" == sv"1.0.0+a"
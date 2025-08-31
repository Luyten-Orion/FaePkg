import std/[sequtils, tables, sets]

import src/engine/[resolution, faever]


proc initGraph*(deps: seq[string]): DependencyGraph =
  result = DependencyGraph()
  for id in deps:
    result.deps[id] = WorkingDependency(id: id)


block: # valid graph test
  let g = initGraph(@["root", "libA", "libB", "libC", "libD", "libE", "libF"])

  g.link("root", "libA", FaeVerConstraint.parse(">=1.0.0"))
  g.link("root", "libB", FaeVerConstraint.parse(">=1.5.0"))
  g.link("libA", "libC", FaeVerConstraint.parse(">=2.0.0"))
  g.link("libB", "libC", FaeVerConstraint.parse(">=2.1.0"))
  g.link("libB", "libD", FaeVerConstraint.parse(">=0.5.0"))
  g.link("libC", "libE", FaeVerConstraint.parse(">=3.0.0"))
  g.link("libD", "libF", FaeVerConstraint.parse(">=1.0.0, <2.0.0"))

  discard g.resolve()

  assert g.deps["libA"].constraint.lo == FaeVer(major: 1)
  assert g.deps["libB"].constraint.lo == FaeVer(major: 1, minor: 5)
  assert g.deps["libC"].constraint.lo == FaeVer(major: 2, minor: 1)
  assert g.deps["libD"].constraint.lo == FaeVer(major: 0, minor: 5)
  assert g.deps["libE"].constraint.lo == FaeVer(major: 3)
  assert g.deps["libF"].constraint.lo == FaeVer(major: 1)


block: # conflicting graph test
  let g = initGraph(@["root", "libA", "libB", "libC", "libD", "libE", "libF"])

  g.link("root", "libA", FaeVerConstraint.parse(">=1.0.0"))
  g.link("root", "libB", FaeVerConstraint.parse(">=1.5.0"))
  g.link("libA", "libC", FaeVerConstraint.parse(">=2.0.0"))
  g.link("libB", "libC", FaeVerConstraint.parse(">=2.1.0"))
  g.link("libB", "libD", FaeVerConstraint.parse(">=0.5.0"))
  g.link("libB", "libE", FaeVerConstraint.parse(">=4.0.5,<4.0.6"))
  g.link("libC", "libE", FaeVerConstraint.parse(">=3.0.0, <4.0.0"))
  g.link("libD", "libE", FaeVerConstraint.parse(">=4.1.0"))
  g.link("libD", "libF", FaeVerConstraint.parse(">=1.0.0, <2.0.0"))

  let res = g.resolve()

  assert "libE" in res, "libE should be in the resolution results"
  assert res["libE"].constraintToSatisfy == FaeVerConstraint.parse(">=4.0.5,<4.0.6")
  assert res["libE"].sq.len == 2
  assert res["libE"].sq.mapIt(it.src).toHashSet == ["libC", "libD"].toHashSet



#for k, v in g.deps:
#  echo k, " -> ", v.constraint.lo
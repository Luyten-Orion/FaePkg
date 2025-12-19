import std/[sequtils, tables, sets]
import experimental/[results]
import src/engine/[resolution, faever]


block: # valid graph test
  #@["root", "libA", "libB", "libC", "libD", "libE", "libF"]
  let g = DependencyGraph()
  g.link("root", "libA", FaeVerConstraint.parse(">=1.0.0"))
  g.link("root", "libB", FaeVerConstraint.parse(">=1.5.0"))
  g.link("libA", "libC", FaeVerConstraint.parse(">=2.0.0"))
  g.link("libB", "libC", FaeVerConstraint.parse(">=2.1.0"))
  g.link("libB", "libD", FaeVerConstraint.parse(">=0.5.0"))
  g.link("libC", "libE", FaeVerConstraint.parse(">=3.0.0"))
  g.link("libD", "libF", FaeVerConstraint.parse(">=1.0.0, <2.0.0"))

  let res = g.resolve()
  assert res.isOk, "Failed to resolve graph: " & $res.error
  let depTbl = res.unsafeGet().mapIt((it.id, it.constr)).toTable

  assert depTbl["libA"].lo == FaeVer(major: 1)
  assert depTbl["libB"].lo == FaeVer(major: 1, minor: 5)
  assert depTbl["libC"].lo == FaeVer(major: 2, minor: 1)
  assert depTbl["libD"].lo == FaeVer(major: 0, minor: 5)
  assert depTbl["libE"].lo == FaeVer(major: 3)
  assert depTbl["libF"].lo == FaeVer(major: 1)


block: # conflicting graph test
  #@["root", "libA", "libB", "libC", "libD", "libE", "libF"]
  let g = DependencyGraph()

  g.link("root", "libA", FaeVerConstraint.parse(">=1.0.0"))
  g.link("root", "libB", FaeVerConstraint.parse(">=1.5.0"))
  g.link("libA", "libC", FaeVerConstraint.parse(">=2.0.0"))
  g.link("libB", "libC", FaeVerConstraint.parse(">=2.1.0"))
  g.link("libB", "libD", FaeVerConstraint.parse(">=0.5.0"))
  g.link("libB", "libE", FaeVerConstraint.parse(">=4.0.5,<4.0.6"))
  g.link("libC", "libE", FaeVerConstraint.parse(">=3.0.0, <4.0.0"))
  g.link("libD", "libE", FaeVerConstraint.parse(">=4.1.0"))
  g.link("libD", "libF", FaeVerConstraint.parse(">=1.0.0, <2.0.0"))

  const SuccessfulData = @[DependencyConflictSource(
    dependentId: "libB",
    constr: FaeVerConstraint.parse(">=4.0.5,<4.0.6")
  )]

  let res = g.resolve()
  assert res.isErr
  let conflicts = res.error()
  assert conflicts.len == 2

  assert conflicts[0].successes == SuccessfulData
  assert conflicts[0].dependencyId == "libE"
  assert conflicts[0].conflicting.dependentId == "libC"
  assert conflicts[0].conflicting.constr == FaeVerConstraint.parse(">=3.0.0,<4.0.0")

  assert conflicts[1].successes == SuccessfulData
  assert conflicts[1].dependencyId == "libE"
  assert conflicts[1].conflicting.dependentId == "libD"
  assert conflicts[1].conflicting.constr == FaeVerConstraint.parse(">=4.1.0")



#for k, v in g.deps:
#  echo k, " -> ", v.constraint.lo
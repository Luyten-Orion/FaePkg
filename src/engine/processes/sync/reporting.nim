import std/[tables, strutils]
import engine/resolution

type
  ConflictReport = object
    successes*: seq[DependencyConflictSource]
    conflicts*: seq[DependencyConflictSource]

proc conflictReport*(conflicts: Conflicts): string =
  const
    ConfOnDepy = " Conflict on dependency: "
    SuccDept = "  Successful dependents:\n"
    ConfDept = "  Conflicting dependents:\n"
    ListArrowLen = 10
  var
    # Dependeny -> ConflictReport
    reports: Table[string, ConflictReport]
    dependentPath: seq[tuple[dependencyId, dependentId: string]]
    finalLen = 2

  # Lol gross code is fun... I figured reports could get pretty big so prealloc
  # the string
  for conflict in conflicts:
    if not reports.hasKey(conflict.dependencyId):
      reports[conflict.dependencyId] = ConflictReport()
      finalLen += ConfOnDepy.len
      finalLen += conflict.dependencyId.len
      finalLen += ConfDept.len
    reports[conflict.dependencyId].conflicts.add(conflict.conflicting)
    let confl = conflict.conflicting
    finalLen += confl.dependentId.len + ListArrowLen + ($confl.constr).len
    for success in conflict.successes:
      if (conflict.dependencyId, success.dependentId) in dependentPath: continue
      finalLen += success.dependentId.len + ListArrowLen + ($success.constr).len
      reports[conflict.dependencyId].successes.add(success)
      dependentPath.add((conflict.dependencyId, success.dependentId))

  result = newStringOfCap(finalLen)
  result &= "\n"
  for depId, report in reports:
    result &= ConfOnDepy & depId & "\n"
    if report.successes.len > 0:
      result &= SuccDept
      for s in report.successes:
        result &= "   - " & s.dependentId & " -> " & $s.constr & "\n"
    if report.conflicts.len > 0:
      result &= "  Conflicting dependents:\n"
      for c in report.conflicts:
        result &= "   - " & c.dependentId & " -> " & $c.constr & "\n"
    result &= "\n"
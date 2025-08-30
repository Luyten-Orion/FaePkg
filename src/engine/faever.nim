import std/[
  algorithm,
  strscans,
  strutils,
  sequtils,
  options
]

import experimental/results

import parsetoml

import ./private/tomlhelpers

type
  FaeVer* = object
    major*, minor*, patch*: int
    prerelease*, buildMetadata*: string

  FaeVerConstraint* = object
    lo*, hi*: FaeVer
    excl*: seq[FaeVer]

  FaeVerOp* = enum
    voEq = "=="
    voLt = "<"
    voLte = "<="
    # No greater than, since we enforce that the lower bound is inclusive
    #voGt = ">"
    voGte = ">="
    voCaret = "^"
    voTilde = "~"

  FaeVerParseError* = enum
    peMalformedInput = "Expected a version in MAJ.MIN.PATCH-PRE+BUILD!"
    peMissingPrerelease = "Trailing dash indicates prerelease, but none was found!"
    peMissingBuildMetadata = "Trailing plus indicates build metadata, but none was found!"
    peMalformedPrerelease = "Prerelease component must be alphanumeric!"
    peMalformedBuildMetadata = "Build metadata component must be alphanumeric!"

  FaeVerParseResult* = Result[FaeVer, FaeVerParseError]

proc neg(T: typedesc[FaeVer]): FaeVer = T(major: -1, minor: -1, patch: -1)
proc low*(T: typedesc[FaeVer]): T = T(major: 0, minor: 0, patch: 0)
proc high*(T: typedesc[FaeVer]): T =
  T(major: int.high, minor: int.high, patch: int.high)


template cmpPrelCmpnt(x, y: string): int =
  template asOpt[T](v: T): Option[T] =
    try:
      some(v)
    except CatchableError:
      none[T]()

  let
    xNum = x.parseUint.asOpt
    yNum = y.parseUint.asOpt
    res = cmp(xNum.isNone, yNum.isNone)

  if res == 0:
    if xNum.isSome: cmp(xNum.unsafeGet, yNum.unsafeGet)
    else: cmp(x, y)
  else: res


template cmpPrel(x, y: string): int =
  var res = 0

  block inner:
    if x != y:
      if x == "":
        res = 1
        break inner
      elif y == "":
        res = -1
        break inner

    let
      xParts = x.split('.')
      yParts = y.split('.')
      length = min(xParts.len, yParts.len)

    for i in 0..<length:
      res = cmpPrelCmpnt(xParts[i], yParts[i])
      if res != 0: break

    res =
      if res == 0:
        if xParts.len > length: 1
        elif yParts.len > length: -1
        else: 0
      else: res
  res


proc cmp*(x, y: FaeVer): int =
  ## Specialised FaeVer compare proc.
  ## 
  ## Returns:
  ## * `-2` if `x` is less than and incompatible with `y`.
  ## * `-1` if `x` is less than and compatible with `y`.
  ## * `0` if `x` is equal to `y`.
  ## * `1` if `x` is greater than and compatible with `y`.
  ## * `2` if `x` is greater than and incompatible with `y`.
  if (x.major, x.minor, x.patch) == (y.major, y.minor, y.patch):
    if x.prerelease.len != 0 and y.prerelease.len != 0:
      result = cmpPrel(x.prerelease, y.prerelease)
    elif x.prerelease.len != 0:
      result = -1
    elif y.prerelease.len != 0:
      result = 1
    
  else:
    if x.major == y.major:
      if x.major == 0:
        result = cmp(x.minor, y.minor).clamp(-1, 1) * 2
        if result == 0: result = cmp(x.patch, y.patch)

      else:
        result = cmp(x.minor, y.minor)
        if result == 0: result = cmp(x.patch, y.patch).clamp(-1, 1)

    else: result = cmp(x.major, y.major).clamp(-1, 1) * 2


template `==`*(x, y: FaeVer): bool = cmp(x, y) == 0
template `<`*(x, y: FaeVer): bool = cmp(x, y) < 0
template `<=`*(x, y: FaeVer): bool = cmp(x, y) <= 0

template `<~`*(x, y: FaeVer): bool = cmp(x, y) == -1
template `>~`*(x, y: FaeVer): bool = cmp(x, y) == 1
template `<=~`*(x, y: FaeVer): bool = cmp(x, y) in [0, -1]
template `>=~`*(x, y: FaeVer): bool = cmp(x, y) in [0, 1]


proc satisfies*(v: FaeVer, c: FaeVerConstraint): bool =
  (v < c.hi and v > c.lo and v notin c.excl)


proc parse*(T: typedesc[FaeVer], s: string): FaeVerParseResult =
  var
    res: FaeVer
    parts = s.split('.', 2)

  if parts.len < 3: return FaeVerParseResult.err(peMalformedInput)

  template parseCmpnt(i: var int, n: string) =
    try:
      i = n.parseInt
    except CatchableError:
      return FaeVerParseResult.err(peMalformedInput)

  parseCmpnt(res.major, parts[0])
  parseCmpnt(res.minor, parts[1])

  for i in 0..<parts[2].len:
    if parts[2][i] notin {'0'..'9'}:
      parts.add parts[2][i..^1]
      parts[2] = parts[2][0..<i]
      break

  parseCmpnt(res.patch, parts[2])

  if parts.len < 4: return FaeVerParseResult.ok(res)

  const ValidIdentifier = {'A'..'Z', 'a'..'z', '0'..'9', '-', '.'}

  # TODO: Validate dot separated identifiers
  if parts[3][0] == '-':
    let subparts = parts[3][1..^1].split('+', 1)

    if not allCharsInSet(subparts[0], ValidIdentifier):
      return FaeVerParseResult.err(peMalformedPrerelease)
    res.prerelease = subparts[0]

    if subparts.len == 2:
      if not allCharsInSet(subparts[1], ValidIdentifier):
        return FaeVerParseResult.err(peMalformedBuildMetadata)
      res.buildMetadata = subparts[1]

    FaeVerParseResult.ok(res)

  elif parts[3][0] == '+':
    let buildMetadata = parts[3][1..^1]

    if not allCharsInSet(buildMetadata, ValidIdentifier):
      return FaeVerParseResult.err(peMalformedBuildMetadata)
    res.buildMetadata = buildMetadata

    FaeVerParseResult.ok(res)

  else:
    FaeVerParseResult.err(peMalformedInput)


proc merge*(a, b: FaeVerConstraint): FaeVerConstraint =
  ## Tries to merge the constraints of `b` into `a`, returning the result
  (result.lo, result.hi) = (max(a.lo, b.lo), min(a.hi, b.hi))
  result.excl = (a.excl & b.excl).filterIt(it in result.lo..result.hi)


template isSatisfiable*(c: FaeVerConstraint): bool =
  c.lo < c.hi or (c.lo == c.hi and c.lo notin c.excl)


proc nextMajor*(v: FaeVer): FaeVer = FaeVer(major: v.major + 1)
proc nextMinor*(v: FaeVer): FaeVer =
  if v.major == 0: FaeVer(minor: v.minor, patch: v.patch + 1)
  else: FaeVer(major: v.major, minor: v.minor + 1)


# TODO: Verify if it is possible to meet the constraint, and find the lowest
# version that does.
proc parse*(T: typedesc[FaeVerConstraint], s: string): T =
  if s.strip(chars={' '}).len == 0:
    raise ValueError.newException("Malformed constraint string: " & s)

  let constraints = block:
    var constrs: seq[tuple[op: FaeVerOp, ver: FaeVer]]

    for constr in s.split(',').mapIt(it.strip(chars={' '})):
      let (op, opLen) = block:
        var opStr = newStringOfCap(2)

        if constr[0] in ['~', '^']: opStr &= constr[0]
        elif constr[0] in ['=', '<', '>']:
          opStr &= $constr[0]
          if constr[1] == '=': opStr &= $constr[1]
          elif not constr[1].isDigit:
            raise newException(ValueError, "Malformed constraint string: " & constr)

        (parseEnum(opStr, voCaret), opStr.len)

      let ver = FaeVer.parse(constr[opLen..^1])

      if ver.isErr:
        raise newException(ValueError, "Malformed constraint string: " & s)

      constrs.add (op, ver.unsafeGet)

    var res: seq[FaeVerConstraint]

    for constr in constrs:
      res.add:
        case constr.op:
        of voEq: FaeVerConstraint(lo: constr.ver, hi: constr.ver)
        of voLt:
          FaeVerConstraint(
          lo: FaeVer.neg, hi: constr.ver, excl: @[constr.ver])
        #of voGt: FaeVerConstraint(
        #  lo: constr.ver, hi: FaeVer.high, excl: @[constr.ver])
        of voLte: FaeVerConstraint(lo: FaeVer.neg, hi: constr.ver)
        of voGte: FaeVerConstraint(lo: constr.ver, hi: FaeVer.high)
        of voCaret: FaeVerConstraint(
          lo: constr.ver, hi: constr.ver.nextMajor, excl: @[constr.ver.nextMajor])
        of voTilde: FaeVerConstraint(
          lo: constr.ver, hi: constr.ver.nextMinor, excl: @[constr.ver.nextMinor])

    res

  assert constraints.len > 0, "You must specify a lower bound at minimum!"
  result = foldl(constraints, merge(a, b))

  assert result.lo != FaeVer.neg, "A lower bound must be supplied!"



proc `$`*(s: FaeVer): string =
  result = $s.major & "." & $s.minor & "." & $s.patch
  if s.prerelease.len != 0:
    result &= "-" & $s.prerelease

  if s.buildMetadata.len > 0:
    result &= "+" & s.buildMetadata


proc fromTomlImpl*(
  res: var FaeVer,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String
  res = FaeVer.parse(t.getStr).get


proc fromTomlImpl*(
  res: var FaeVerConstraint,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String
  res = FaeVerConstraint.parse(t.getStr)
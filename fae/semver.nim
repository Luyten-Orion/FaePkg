import std/[
  strscans,
  strutils,
  options
]

import parsetoml

import ./tomlhelpers

type
  SemVer* = object
    major*, minor*, patch*: int
    prerelease*, buildMetadata*: string


template asOpt[T](v: T): Option[T] =
  try:
    some(v)
  # It loses the original error but seeing as it's only used for `parseUnt`...
  except CatchableError:
    none[T]()


template cmpPrelCmpnt(x, y: string): int =
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

proc cmp*(x, y: SemVer): int =
  ## SemVer compare proc.
  ## 
  ## Returns:
  ## * `0` if exactly equal.
  ## * `1` if `x` is compatible with `y`.
  ## * `-1` if `y` is compatible with `x`.
  ## * `2` if `x` is greater than `y`.
  ## * `-2` if `y` is greater than `x`.
  if (x.major, x.minor, x.patch) == (y.major, y.minor, y.patch):
    result = cmpPrel(x.prerelease, y.prerelease)
  else:
    if x.major == y.major:
      if x.major == 0:
        result = cmp(x.minor, y.minor) * 2
        if result == 0: result = cmp(x.patch, y.patch)

      else:
        result = cmp(x.minor, y.minor)
        if result == 0: result = cmp(x.patch, y.patch)

    else: result = cmp(x.major, y.major) * 2


template `==`*(x, y: SemVer): bool = cmp(x, y) == 0
template `<`*(x, y: SemVer): bool = cmp(x, y) < 0

template `<~`*(x, y: SemVer): bool = cmp(x, y) == -1
template `>~`*(x, y: SemVer): bool = cmp(x, y) == 1
template `<=~`*(x, y: SemVer): bool = cmp(x, y) in [0, -1]
template `>=~`*(x, y: SemVer): bool = cmp(x, y) in [0, 1]

proc parse*(T: typedesc[SemVer], s: string): T =
  var
    r = SemVer()
    rest: string

  if not s.strip(chars={' '}).scanf(
    "$i.$i.$i$*$.", r.major, r.minor, r.patch, rest):
    raise newException(ValueError, "Malformed version string: " & s)

  if rest.len == 0:
    return r
  elif rest[0] == '-':
    let parts = rest[1..^1].split('+', 1)
    r.prerelease = parts[0]
    if parts.len == 2:
      r.buildMetadata = parts[1]
  elif rest[0] == '+':
    r.buildMetadata = rest[1..^1]
  else:
    raise newException(ValueError, "Malformed version string: " & s)

  return r


proc `$`*(s: SemVer): string =
  result = $s.major & "." & $s.minor & "." & $s.patch
  if s.prerelease.len > 0:
    result &= "-" & s.prerelease
  if s.buildMetadata.len > 0:
    result &= "+" & s.buildMetadata


proc fromTomlImpl*(
  res: var SemVer,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String
  res = SemVer.parse(t.getStr)
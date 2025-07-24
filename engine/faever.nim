import std/[
  strscans,
  strutils,
  options
]

import parsetoml

import ./private/tomlhelpers

type
  # We mostly follow SemVer, we don't support arbitrary prereleases though.
  FaeVer* = object
    major*, minor*, patch*: int
    prerelease*: Option[FaeVerPreRelease]
    buildMetadata*: string

  FaeVerPreRelease* = object
    kind*: FaeVerPrereleaseKind
    ver*: range[-1..int.high]

  # Prereleases are enforced to be these options, with the priority
  # `unstable` < `alpha` < `beta` < `rc`
  FaeVerPrereleaseKind* = enum
    spUnstable = "unstable"
    spAlpha = "alpha"
    spBeta = "beta"
    spRC = "rc"

  # Maybe replace this with a more flexible 'FaeVerConstraint' object
  FaeVerRange* = object
    # `-1` means unconstrained
    major*, minor*, patch*: tuple[lo, hi: range[-1..int.high]]
    # Depending on a prerelease is highly discouraged
    permittedPrereleases*: set[FaeVerPrereleaseKind]
    prereleaseVersion*: range[-1..int.high]


template `<`*(x, y: FaeVerPrereleaseKind): bool = ord(x) < ord(y)


template cmpPrel(x, y: FaeVerPreRelease): int =
  if x.kind == y.kind:
    if x.ver == -1: -1
    elif y.ver == -1: 1
    else: cmp(x.ver, y.ver)
  else:
    cmp(x.kind, y.kind)

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
    if x.prerelease.isSome and y.prerelease.isSome:
      result = cmpPrel(x.prerelease.unsafeGet, y.prerelease.unsafeGet)
    elif x.prerelease.isSome:
      result = -1
    elif y.prerelease.isSome:
      result = 1
    
  else:
    if x.major == y.major:
      if x.major == 0:
        result = cmp(x.minor, y.minor) * 2
        if result == 0: result = cmp(x.patch, y.patch)

      else:
        result = cmp(x.minor, y.minor)
        if result == 0: result = cmp(x.patch, y.patch)

    else: result = cmp(x.major, y.major) * 2


template `==`*(x, y: FaeVer): bool = cmp(x, y) == 0
template `<`*(x, y: FaeVer): bool = cmp(x, y) < 0

template `<~`*(x, y: FaeVer): bool = cmp(x, y) == -1
template `>~`*(x, y: FaeVer): bool = cmp(x, y) == 1
template `<=~`*(x, y: FaeVer): bool = cmp(x, y) in [0, -1]
template `>=~`*(x, y: FaeVer): bool = cmp(x, y) in [0, 1]

proc parse*(T: typedesc[FaeVer], s: string): T =
  var
    r = FaeVer()
    rest: string

  if not s.strip(chars={' '}).scanf(
    "$i.$i.$i$*$.", r.major, r.minor, r.patch, rest):
    raise newException(ValueError, "Malformed version string: " & s)

  if rest.len == 0:
    return r
  elif rest[0] == '-':
    let parts = rest[1..^1].split('+', 1)

    if parts[0].len == 0:
      raise newException(ValueError, "Malformed version string: " & s)

    let preParts = parts[0].split('.', 1)

    let ver = if preParts.len == 2:
        try:
          let ver = parseInt(preParts[1])
          if ver < 0: raise newException(ValueError,
            "Malformed version string: " & s)
          ver
        except ValueError:
          raise newException(ValueError, "Malformed version string: " & s)
      else:
        -1

    try:
      const PrereleaseTable = {"unstable": spUnstable, "alpha": spAlpha,
        "beta": spBeta, "rc": spRC}.toTable()

      r.prerelease = some(FaeVerPreRelease(
        kind: PrereleaseTable[preParts[0].toLowerAscii], ver: ver))
    except KeyError:
      raise newException(ValueError, "Malformed version string: " & s)

    if parts.len == 2:
      r.buildMetadata = parts[1]
  elif rest[0] == '+':
    r.buildMetadata = rest[1..^1]
  else:
    raise newException(ValueError, "Malformed version string: " & s)

  return r


proc `$`*(s: FaeVer): string =
  result = $s.major & "." & $s.minor & "." & $s.patch
  if s.prerelease.isSome:
    result &= "-" & $s.prerelease.unsafeGet

    let ver = s.prerelease.unsafeGet.ver
    if ver != -1:
      result &= "." & $ver

  if s.buildMetadata.len > 0:
    result &= "+" & s.buildMetadata


proc fromTomlImpl*(
  res: var FaeVer,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String
  res = FaeVer.parse(t.getStr)
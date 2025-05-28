import std/[
  strscans,
  strutils
]

import parsetoml

import ./tomlhelpers

type
  SemVer* = object
    major*, minor*, patch*: int
    prerelease*, buildMetadata*: string



proc parse*(T: typedesc[SemVer], s: string): T =
  var
    r = SemVer()
    rest: string

  if not s.scanf(
    "$i.$i.$i$*$.", r.major, r.minor, r.patch, rest):
    raise newException(ValueError, "Malformed version string: " & s)

  rest = rest.strip(chars={' '})

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
import std/[strutils, random, os]

const ValidChars* = Letters + Digits

proc randomSuffix*(inPath: string): string =
  var randStr = newStringOfCap(8)
  for i in 0..<8:
    randStr.add(ValidChars.sample())

  if inPath.endsWith(DirSep):
    return inPath[0..^2] & "_" & randStr
  return inPath & randStr

template collect*(initer: typed, body: untyped): untyped =
  block:
    var it{.inject.} = initer
    body
    it

proc getOrDefault*[T](s: seq[T], idx: int, default: T): T =
  if idx < s.len: s[idx] else: default

proc getOrDefault*[T](s: seq[T], idx: BackwardsIndex, default: T): T =
  s.getOrDefault(s.len - idx.int, default)
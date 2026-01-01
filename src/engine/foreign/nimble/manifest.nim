import std/[strutils, os]

type
  NimbleManifest* = object
    packageName*: string
    srcDir*: string
    requiresData*: seq[string]

proc extractStrings(s: string): seq[string] =
  let 
    possibleStrings = s.split('\"')
    start = possibleStrings[0].startsWith("requires").ord
  for i in start..possibleStrings.high:
    let str = possibleStrings[i]
    if str.len > 0 and str[0] in Letters + Digits:
      result.add str

proc parseNimble*(file: string, content: string): NimbleManifest =
  result.packageName = file.extractFilename().splitFile().name
  var inRequire = false

  for line in content.splitLines:
    if line.toLower.startsWith("srcdir"):
      result.srcDir = line[line.find('"') + 1..line.rfind('"') - 1]
    elif (let first = line.find(AllChars - Whitespace); line.continuesWith("requires", max(first - 1, 0))):
      inRequire = true
      result.requiresData.add line.extractStrings()
    elif inRequire and (let ind = line.find(AllChars - WhiteSpace); ind >= 0 and line[ind] == '\"'):
      result.requiresData.add line.extractStrings()
    else:
      inRequire = false
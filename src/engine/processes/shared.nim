import std/[
  strformat,
  sequtils,
  strutils,
  tables,
  uri,
  os
]

import parsetoml

import ../private/tomlhelpers
import ../[
  resolution,
  schema,
  faever
]

type
  PackageData* = object
    origin*: string
    id*: string
    loc*: Uri
    subdir*: string
    diskLoc*: string


# TODO: Figure out a way to gently enforce package IDs having the major version
# suffixed.
proc toId*(dep: DependencyV0): string =
  result = [dep.src, dep.subdir]
    .filterIt(not it.isEmptyOrWhitespace)
    .join("/")

  if dep.constr.lo.major != 0:
    result &= "@" & $dep.constr

proc toPkgData*(dep: DependencyV0): PackageData =
  PackageData(
    id: dep.toId,
    origin: dep.origin,
    loc: parseUri(&"{dep.scheme}://{dep.src}"),
    subdir: dep.subdir
  )


proc toPkgData*(man: ManifestV0): PackageData =
  PackageData(id: man.package.name)


proc getFolderName*(src: PackageData): string =
  for part in src.id.split('/'):
    for c in part:
      if c == '!': result.add("!!")
      elif c.isUpperAscii:
        result.add('!')
        result.add(c.toLowerAscii)
      # underscores aren't forbidden, but we're using it to signify hex chars
      elif c in {'_', '/', '<', '>', ':', '"', '\\', '|', '?', '*'}:
        result.add('_')
        result.add toHex(c.byte).toLowerAscii
      # TODO: Be a bit more picky, not wanting to indiscriminately replace
      # all non-alphanumeric chars, since some symbols are good
      #elif not c.isAlphaNumeric:
      #  result.add(c)
      #  result.add toHex(c.byte).toLowerAscii
      else:
        result.add(c)
    result.add(DirSep)


proc ensureDirExists*(dir: string, sep = DirSep, currDir = ".") =
  var currDir = currDir

  for p in dir.relativePath(currDir).split(sep):
    currDir = currDir / p
    if not dirExists(currDir):
      createDir(currDir)


proc registerDep*(
  pkgMap: var Table[string, PackageData],
  g: DependencyGraph,
  fromId: string,
  pkgData: PackageData,
  constr: FaeVerConstraint
) =
  let id = pkgData.id

  if id notin pkgMap: pkgMap[id] = pkgData
  g.add(id)
  try:
    g.link(id, fromId, constr)
  except ValueError:
    quit &"Failed to register dependency, invalid constraint {constr}: " & id, 1


proc parseManifest*(f: string, dir = "."): ManifestV0 =
  var res: ManifestV0
  let file = f
  try:
    res = ManifestV0.fromToml(parseFile(file))
  except IOError:
    quit("No package.skull.toml found in `" & file.parentDir.relativePath(dir) &
      "`, not a Fae project!", 1)
  except TomlError as e:
    quit("Failed to parse the package manifest: " & e.msg, 1)
  res
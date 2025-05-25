import std/[
  sequtils,
  options,
  tables,
  macros
]

import parsetoml

const LatestFaeFormat = 0

# Some pragmas for making deserialisation cleaner
template rename*(name: string) {.pragma.}
template tag*(field: string, value: Ordinal) {.pragma.}

# Data types
type
  PinKind* = enum
    # TODO: Replace `Reference` with a more appropriate name
    Version, Reference

  SemVer* = object
    major*, minor*, patch*: int
    prerelease*, buildMetadata*: seq[string]

  PkgManifest* = object
    format*: uint
    metadata* {.rename: "package"}: PkgMetadata
    # ordered table so it can be serialised in the same order
    repositories*: OrderedTable[string, Repository]

  PkgMetadata* = object
    vcs*: string
    authors*: seq[string]
    description*, license*: string
    srcDir* {.rename: "src-dir"}: Option[string]
    binDir* {.rename: "bin-dir"}: Option[string]
    bin*: seq[string]
    documentation*, source*, homepage*: string
    # For any data that isn't relevant to Fae, but exists for other tools
    ext*: TomlTableRef

  Repository* = object
    vcs*: string
    protocols*: seq[string]
    host*: string

  # The name of the dependency is irrelevant to Fae, since it'll use the name
  # the repo is checked out as, unless explicitly overridden with `relocate`
  PkgDependency* = object
    # `src` follows the format `<repo>:<path>`, anything after the semicolon is
    # passed to the appropriate VCS plugin (through the repository definition).
    # so `git+ssh@github.com:user/repo` is the same as
    # `gh:user/repo`. `path` is also a valid repository which uses file paths.
    src*, relocate*: string
    case pin*: PinKind
    of Version: version* {.tag("pin", Version).}: SemVer
    of Reference:
      # Left as a string since it's interpreted by the vcs plugin
      refr* {.rename: "ref", tag("pin", Reference).}: string

  TomlDecoderConfig* = object
    rejectUnknownFields*: bool ## Error on unknown fields if true
    allowMissingFields*: bool ## Ignore missing fields if true


const DefaultDecoderConfig = TomlDecoderConfig(
  rejectUnknownFields: true,
  allowMissingFields: false
)


# Decoding stuff
proc fromTomlImpl*[T: object](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  #mixin fromTomlImpl

  assert t.kind == TomlValueKind.Table, "Can only unpack objects from tables."

  template getFieldName(
    nm: string,
    field: untyped
  ): string =
    when not hasCustomPragma(field, rename): nm
    else: getCustomPragmaVal(field, rename)

  const FieldNames = block:
    var fields: seq[string]

    for nm, field in res.fieldPairs:
      fields.add getFieldName(nm, field)

    fields

  let
    tbl = t.getTable
    tblFields = toSeq(tbl.keys)

  if conf.rejectUnknownFields:
    for key in tblFields:
      if key notin FieldNames:
        raise newException(KeyError, "Unknown field: " & key)

  if not conf.allowMissingFields:
    for key in FieldNames:
      if key notin tblFields:
        raise newException(KeyError, "Missing field: " & key)

  for key, value in tbl:
    block outerLoop:
      for nm, field in res.fieldPairs:
        const FieldName = getFieldName(nm, field)

        if key == FieldName: field.fromTomlImpl(value, conf)
        else: break outerLoop


proc fromTomlImpl*(
  res: var string,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String
  res = t.getStr


proc fromTomlImpl*[T: SomeInteger](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.Int
  res = T(t.getInt)


proc fromTomlImpl*(
  res: var bool,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.Bool
  res = t.getBool


proc fromTomlImpl*[T: SomeFloat](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.Float
  res = T(t.getFloat)


proc fromTomlImpl*[T](
  res: var seq[T],
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  assert t.kind == TomlValueKind.Array

  let arr = t.getElems
  res.setLen(arr.len)

  for i in 0..<arr.len:
    res[i].fromTomlImpl(arr[i], conf)


proc fromTomlImpl*[T](
  res: var (Table[string, T] | OrderedTable[string, T]),
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  assert t.kind == TomlValueKind.Table

  for key, value in t.getTable:
    res[key] = when T is ref: new(T) else: default(T)
    res[key].fromTomlImpl(value, conf)


proc fromTomlImpl*[T: ref](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  if res == nil:
    res = new(T)
  res[].fromTomlImpl(t, conf)


proc fromToml*[T: not ref](
  _: typedesc[T],
  t: TomlValueRef,
  conf = DefaultDecoderConfig
): T =
  mixin fromTomlImpl

  result.fromTomlImpl(t, conf)


proc fromToml*[T: ref](
  _: typedesc[T],
  t: TomlValueRef,
  conf = DefaultDecoderConfig
): T =
  mixin fromTomlImpl

  result = T()

  result[].fromTomlImpl(t, conf)


type
  Obj = ref object
    a {.rename: "a-dash".}: int

  Test = object
    format: int
    data: Table[string, float]
    arr: seq[int]
    b: bool
    nested: Obj


proc `$`(o: Obj): string = $o[]

let tomlData = parseString("""
format = 1
data = { "a" = 2.0, "b" = 3.0 }
arr = [ 1, 2, 3 ]
b = true
nested = { "a-dash" = 1 }
""", "string>")

echo tomlData.toTomlString

echo Test.fromToml(tomlData)
import std/[
  strutils,
  sequtils,
  options,
  tables,
  macros,
  uri
]

import parsetoml

import "."/[
  tomldecode,
  tomlcommon
]

type
  #TomlTableSyntax* = enum
  #  tosUnset, tosAos, tosInline

  # During dumping, this object is removed anyway, it's purely here for
  # allowing tables to be formatted
  TomlEncoderConfig* = object
    isFaeTomlEncoder {.rename: "is-fae-toml-encoder".}: bool
    #defaultTableSyntax: TomlTableSyntax
    omitOptionalDefaults {.ignore.}: bool
    maxLineLen* {.ignore.}: int
    #node: TomlValueRef


const DefaultEncoderConfig* = TomlEncoderConfig(
  isFaeTomlEncoder: true,
  #defaultTableSyntax: tosAos,
  omitOptionalDefaults: true,
  maxLineLen: 80
)


proc fromTomlImpl*(
  res: var TomlEncoderConfig,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) = tomldecode.fromTomlImpl(res, t, conf)


# Gotta love gross hacks~ I should fork `parsetoml` or make my own toml lib atp
#[
proc wrap(
  conf: TomlEncoderConfig,
  n: TomlValueRef,
  tableSyntax = tosUnset
): TomlEncoderConfig =
  let setTableSyntax = if tableSyntax != tosUnset:
      tableSyntax
    else:
      conf.defaultTableSyntax

  TomlEncoderConfig(
    isFaeTomlEncoder: conf.isFaeTomlEncoder,
    defaultTableSyntax: setTableSyntax,
    node: n
  )
]#


#template preferStructure*(syntax: TomlTableSyntax) {.pragma.}
template omitDefaultOpt* {.pragma.}
template tomlNone: TomlValueRef = TomlValueRef(kind: TomlValueKind.None)

proc toTomlImpl*(s: string, conf: TomlEncoderConfig): TomlValueRef = ?s
proc toTomlImpl*(n: SomeNumber, conf: TomlEncoderConfig): TomlValueRef = ?n
proc toTomlImpl*(b: bool, conf: TomlEncoderConfig): TomlValueRef = ?b
proc toTomlImpl*(u: Uri, conf: TomlEncoderConfig): TomlValueRef = ?u
proc toTomlImpl*(t: TomlValueRef, conf: TomlEncoderConfig): TomlValueRef = t
proc toTomlImpl*[T: enum](e: T, conf: TomlEncoderConfig): TomlValueRef = ?e

proc toTomlImpl*[T](o: Option[T], conf: TomlEncoderConfig): TomlValueRef =
  mixin toTomlImpl
  if o.isSome: toTomlImpl(o.unsafeGet, conf)
  else: tomlNone


proc toTomlImpl*[T](o: openArray[T], conf: TomlEncoderConfig): TomlValueRef =
  mixin toTomlImpl
  result = newTArray()
  for v in o: result.arrayVal.add toTomlImpl(v, conf)


proc toTomlImpl*[T: object](obj: T, conf: TomlEncoderConfig): TomlValueRef =
  mixin toTomlImpl
  result = newTTable()

  for k, v in obj.fieldPairs:
    block outer:
      const
        ShouldIgnore = hasCustomPragma(v, ignore)
        IsOptional = hasCustomPragma(v, optional)

      when ShouldIgnore: break outer

      when IsOptional:
        if conf.omitOptionalDefaults and v == getCustomPragmaVal(v, optional).default:
            break outer

      when v is Option:
        if v.isNone: break outer

      let name =
        when hasCustomPragma(v, rename): getCustomPragmaVal(v, rename)
        else: k

      # TODO: To implement this, we need a custom dumper
      #if hasCustomPragma(v, preferStructure):
      #  result.tableVal[name] = toTomlImpl(conf.wrap(
      #    toTomlImpl(v), getCustomPragmaVal(v, preferStructure)
      #  ), conf)
      #else:
      result.tableVal[name] = toTomlImpl(v, conf)


proc toTomlImpl*[T](tbl: Table[string, T] | OrderedTable[string, T], conf: TomlEncoderConfig): TomlValueRef =
  mixin toTomlImpl
  result = newTTable()
  for key, val in pairs(tbl): result.tableVal[key] = toTomlImpl(val, conf)


proc toTomlImpl*[T](o: ref T, conf: TomlEncoderConfig): TomlValueRef =
  mixin toTomlImpl

  if o == nil: tomlNone
  else: toTomlImpl(o[], conf)


proc toToml*[T](
  o: T,
  conf = DefaultEncoderConfig
): TomlValueRef =
  mixin toTomlImpl

  toTomlImpl(o, conf)


proc dumpToml*[T](v: T, conf = DefaultEncoderConfig): string =
  $toToml(v, conf)
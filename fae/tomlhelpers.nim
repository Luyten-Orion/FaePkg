import std/[
  strutils,
  sequtils,
  options,
  tables,
  macros,
  uri
]

import parsetoml


# Some pragmas for making deserialisation cleaner
template rename*(name: string) {.pragma.}
# TODO: Make `tag` work... basically, fix case object deserialisation
template tag*(field: string, value: Ordinal) {.pragma.}
template ignore* {.pragma.}
template optional* {.pragma.}


type
  # TODO: Maybe add a name callback hook or smth and provide some built-in ones?
  # Like lowerCamelCase, snake-case, nim identifier case, etc
  TomlDecoderConfig* = object
    rejectUnknownFields*: bool ## Error on unknown fields if true
    allowMissingFields*: bool ## Ignore missing fields if true


const DefaultDecoderConfig = TomlDecoderConfig(
  rejectUnknownFields: true,
  allowMissingFields: false
)


# Decoding stuff
proc fromTomlImpl*(
  t: var TomlValue,
  t2: TomlValueRef,
  conf: TomlDecoderConfig
) =
  t = t2[]


proc fromTomlImpl*[T: object](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl

  assert t.kind == TomlValueKind.Table, "Can only unpack objects from tables."

  template getFieldName(
    nm: string,
    field: untyped
  ): string =
    when not hasCustomPragma(field, rename): nm
    else: getCustomPragmaVal(field, rename)

  var
    fieldNames, optionalFields: seq[string]

  for nm, field in res.fieldPairs:
    if not hasCustomPragma(field, ignore):
      fieldNames.add getFieldName(nm, field)
      when field is (seq | Option | OrderedTable | Table):
        optionalFields.add getFieldName(nm, field)

  let
    tbl = t.getTable
    tblFields = toSeq(tbl.keys)

  if conf.rejectUnknownFields:
    for key in tblFields:
      if key notin fieldNames:
        raise newException(KeyError, "Unknown field: " & key)

  if conf.allowMissingFields:
    var excl: seq[string]

    for key in fieldNames:
      if key notin tblFields:
        excl.add key

    fieldNames = fieldNames.filterIt(it notin excl)
  else:
    for key in fieldNames:
      if key notin tblFields and key notin optionalFields:
        raise newException(KeyError, "Missing field: " & key)

  for nm, field in res.fieldPairs:
    const FieldName = getFieldName(nm, field)

    if FieldName in tblFields:
      field.fromTomlImpl(tbl[FieldName], conf)


proc fromTomlImpl*[T: enum](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  case t.kind
  of TomlValueKind.String:
    res = parseEnum[T](t.getStr)
  of TomlValueKind.Int:
    res = T(t.getInt)
  else:
    assert t.kind in {TomlValueKind.String, TomlValueKind.Int}


proc fromTomlImpl*(
  res: var string,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String
  res = t.getStr


proc fromTomlImpl*(
  res: var Uri,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  assert t.kind == TomlValueKind.String, "Uri must be a string but got: " &
    $t.kind
  res = parseUri(t.getStr)


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

  template defaultVal: T = (when T is ref: new(T) else: default(T))

  for key, value in t.getTable:
    res[key] = defaultVal()
    res[key].fromTomlImpl(value, conf)


proc fromTomlImpl*[T, U](
  res: var (Table[T, U] | OrderedTable[T, U]),
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  assert t.kind == TomlValueKind.Table

  template defaultVal(V: typedesc[T | U]): V = (when V is ref: new(V) else: default(V))

  for key, value in t.getTable:
    var k = defaultVal(T)
    k.fromTomlImpl(?key, conf)
    res[k] = defaultVal(U)
    res[k].fromTomlImpl(value, conf)


proc fromTomlImpl*[T: ref](
  res: var T,
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl
  if res == nil:
    res = new(T)
  res[].fromTomlImpl(t, conf)


proc fromTomlImpl*[T](
  res: var Option[T],
  t: TomlValueRef,
  conf: TomlDecoderConfig
) =
  mixin fromTomlImpl

  if t.kind == TomlValueKind.None:
    res = none(T)
  else:
    var inner = when T is ref: new(T) else: default(T)
    inner.fromTomlImpl(t, conf)
    res = some(move(inner))


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
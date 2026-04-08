import std/tables
import faepkg/core/types

type
  SymbolTable* = object
    strings: seq[string]
    lookup: Table[string, StringId]

proc getOrPut*(st: var SymbolTable, s: string): StringId =
  if st.lookup.hasKey(s):
    return st.lookup[s]
  
  let newId = StringId(st.strings.len.uint32)
  st.strings.add(s)
  st.lookup[s] = newId
  return newId

proc initSymbolTable*(): SymbolTable =
  result = SymbolTable(
    strings: newSeq[string](),
    lookup: initTable[string, StringId]()
  )
  discard result.getOrPut("")

proc getString*(st: SymbolTable, id: StringId): string =
  let idx = id.uint32
  if idx < st.strings.len.uint32:
    return st.strings[idx]
  return ""
import std/[
  uri # When working with origins, URIs are used since they provide needed info
]

import parsetoml

#[
TODO:
 * Add a way to have origin-specific configs (probably a JsonNode object?)
 * Add a normalisation callback (with the config passed to the function ofc)
 * Add a URI expansion callback? This could be omitted if ops like cloning and
   fetching automatically use the correct URI.
]#

import badresults

type
  OriginCloneErrEnum* = enum
    NotFound, TimedOut, Other

  OriginCloneErr* = object
    case kind*: OriginCloneErrEnum
    of {NotFound, TimedOut}: discard
    of Other: msg*: string

  OriginCloneResult* = Result[string, OriginCloneErr]

  OriginTagList* = object
    tags*: seq[string]

  # Used for passing around config data
  OriginContext* = ref object of RootObj

  OriginAdapter* = ref object of RootObj
    
    # ----Callback functions----
    constructCtxCb: proc(config: TomlValueRef): OriginContext
    # Cloning and fetching are similar enough operations anyway
    cloneCb: proc(uri: Uri): OriginCloneResult
    fetchCb: proc(uri: Uri): OriginCloneResult
    tagsCb: proc()



proc newOriginAdapter*(
  cloneCb: proc(uri: Uri): OriginCloneResult,
  fetchCb: proc(uri: Uri): OriginCloneResult
): OriginAdapter =
  OriginAdapter(cloneCb: cloneCb, fetchCb: fetchCb)


proc constructCtx*(
  oa: OriginAdapter,
  config: TomlValueRef
): OriginContext {.inline.} = oa.constructCtxCb(config)

proc clone*(oa: OriginAdapter, uri: Uri): OriginCloneResult {.inline.} =
  oa.cloneCb(uri)

proc fetch*(oa: OriginAdapter, uri: Uri): OriginCloneResult {.inline.} =
  oa.fetchCb(uri)

proc tags*(oa: OriginAdapter): OriginTagList {.inline.} =
  oa.tagsCb()

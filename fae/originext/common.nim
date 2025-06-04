import std/[
  uri # When working with origins, URIs are used since they provide needed info
]

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

  OriginAdapter* = ref object of RootObj
    # Cloning and fetching are similar enough operations anyway
    cloneCb: proc(uri: Uri): OriginCloneResult
    fetchCb: proc(uri: Uri): OriginCloneResult


proc newOriginAdapter*(
  cloneCb: proc(uri: Uri): OriginCloneResult,
  fetchCb: proc(uri: Uri): OriginCloneResult
): OriginAdapter =
  OriginAdapter(cloneCb: cloneCb, fetchCb: fetchCb)


proc clone*(oa: OriginAdapter, uri: Uri): OriginCloneResult {.inline.} =
  oa.cloneCb(uri)

proc fetch*(oa: OriginAdapter, uri: Uri): OriginCloneResult {.inline.} =
  oa.fetchCb(uri)
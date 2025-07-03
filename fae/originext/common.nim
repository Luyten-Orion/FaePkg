import std/[
  # Some simple URI normalisation
  strutils,
  # The fetch/clone op returns a 'Process' object
  osproc,
  # Make proc type decls nicer
  sugar,
  # When working with origins, URIs are used since they provide needed info
  uri
]

#import parsetoml
import badresults

import ../tomlhelpers

#[
TODO:

 * Add a way to have origin-specific configs (probably a JsonNode object?)
 * Add a normalisation callback (with the config passed to the function ofc)
 * Add a URI expansion callback? This could be omitted if ops like cloning and
   fetching automatically use the correct URI.
]#

type
  OriginCloneErrEnum* = enum
    NotFound, TimedOut, Unreachable, Unauthorised,
    NonEmptyTargetDir, TargetIsFile, Other

  OriginFetchErr* = object
    case kind*: OriginCloneErrEnum
    of {NotFound, TimedOut, Unreachable, Unauthorised, NonEmptyTargetDir,
      TargetIsFile}: discard
    of Other: msg*: string

  # TODO: Custom general-purpose 'Process' type
  OriginFetchResult* = Result[void, OriginFetchErr]

  OriginTags* = object
    # TODO: Split this up into semver-compliant and 'other'?
    tags*: seq[string]

  OriginTagsResult* = Result[OriginTags, string]

  # Callback types
  OriginGetDirProc* = (OriginContext, Uri) -> string
  OriginCloneProc* = (OriginContext, Uri) -> OriginFetchResult
  OriginFetchProc* = (OriginContext, Uri) -> OriginFetchResult
  OriginTagsProc* = (OriginContext, Uri) -> OriginTagsResult
  OriginCheckoutProc*  = (OriginContext, Uri, string) -> bool
  OriginNormaliseUriProc* = (OriginContext, Uri) -> Uri

  # TODO: Add 'hash' callback or something similar, for verifying integrity.
  OriginAdapterCallbacks* = object
    getDir*: OriginGetDirProc
    clone*: OriginCloneProc
    fetch*: OriginFetchProc
    tags*: OriginTagsProc
    checkout*: OriginCheckoutProc
    normaliseUri*: OriginNormaliseUriProc
    isRemote*: void -> bool

  # Used for passing around config data
  # TODO: Have some 'base configuration' set here, for dep dir locs for example.
  OriginContext* = ref object of RootObj
    scheme* {.optional("").}: string
    # Leave `host` empty if not applicable
    host* {.ignore.}: string

  OriginAdapter* = ref object of RootObj
    ctx*: OriginContext
    cb: OriginAdapterCallbacks


# TODO: Maybe move this to a common utility file?
template `|=`*[T](x: var T, f: proc(x: T): T) = x = f(x)
template `|>`*[T, U](x: T, f: proc(x: T): U): U = f(x)


proc newOriginAdapter*(
  callbacks: OriginAdapterCallbacks
): OriginAdapter =
  for cbName, cbVal in callbacks.fieldPairs:
    assert cbVal != nil, "Callbacks cannot be nil!"

  result = OriginAdapter(cb: callbacks)


proc normaliseUri*(oa: OriginAdapter, uri: Uri): Uri =
  # We have some shared behaviour so, toss it all here before the adapter sees
  # it. Assumes URIs have been expanded already, too.
  result = uri

  result.scheme |= toLowerAscii
  result.hostname |= toLowerAscii
  # maybe don't do this?
  if not result.opaque and result.path == "": result.path = "/"
  # lets be more elegant than this...
  if result.port != "": result.port = $parseInt(result.port)

  result = oa.cb.normaliseUri(oa.ctx, result)


proc getDir*(oa: OriginAdapter, uri: Uri): string =
  oa.cb.getDir(oa.ctx, oa.normaliseUri(uri))

proc clone*(oa: OriginAdapter, uri: Uri): OriginFetchResult {.inline.} =
  oa.cb.clone(oa.ctx, oa.normaliseUri(uri))

proc fetch*(oa: OriginAdapter, uri: Uri): OriginFetchResult {.inline.} =
  oa.cb.fetch(oa.ctx, oa.normaliseUri(uri))

proc tags*(oa: OriginAdapter, uri: Uri): OriginTagsResult {.inline.} =
  oa.cb.tags(oa.ctx, oa.normaliseUri(uri))

proc isRemote*(oa: OriginAdapter): bool {.inline.} =
  oa.cb.isRemote()
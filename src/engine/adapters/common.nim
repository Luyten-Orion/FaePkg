import std/[
  options,
  tables
]

import parsetoml

import ../schema

type
  OriginContext* = object
    config*: TomlTable
    targetDir*: string

  # TODO: Maybe a context object would be useful...
  OriginAdapter* = object
    # TODO: Maybe a callback for fetching only the manifest?
    # this is a large stroke of code though, many actions bundled into one proc.
    cloneImpl*: proc(ctx: OriginContext, url: string): bool {.closure.}
    fetchImpl*: proc(ctx: OriginContext, url, refr: string): bool {.closure.}
    resolveImpl*: proc(ctx: OriginContext, refr: string): Option[string] {.closure.}
    checkoutImpl*: proc(ctx: OriginContext, refr: string): bool {.closure.}


# Populated at startup, should never be modified afterwards... Can't enforce
# that though
var origins*: Table[string, OriginAdapter]

# TODO: Could potentially implement a 'foreign' adapter, that we search for on
# fae's startup? Similar to how shit like cargo works, when adding custom tools


proc clone*(adapter: OriginAdapter, ctx: OriginContext, url: string): bool =
  adapter.cloneImpl(ctx, url)


proc fetch*(adapter: OriginAdapter, ctx: OriginContext, url, refr: string): bool =
  adapter.fetchImpl(ctx, url, refr)


proc resolve*(adapter: OriginAdapter, ctx: OriginContext, refr: string): Option[string] =
  adapter.resolveImpl(ctx, refr)


proc checkout*(adapter: OriginAdapter, ctx: OriginContext, refr: string): bool =
  adapter.checkoutImpl(ctx, refr)
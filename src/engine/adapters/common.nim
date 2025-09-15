import std/[
  options,
  tables
]

from std/sugar import `->`

import parsetoml

import ../schema

type
  OriginContext* = object
    targetDir*: string

  # TODO: Maybe a context object would be useful...
  OriginAdapter* = object
    # TODO: Maybe a callback for fetching only the manifest?
    # this is a large stroke of code though, many actions bundled into one proc.
    cloneImpl*: (ctx: OriginContext, url: string) -> bool
    fetchImpl*: (ctx: OriginContext, url: string, refr: string) -> bool
    resolveImpl*: (ctx: OriginContext, refr: string) -> Option[string]
    checkoutImpl*: (ctx: OriginContext, refr: string) -> bool
    isVcs*: (ctx: OriginContext) -> bool


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


proc isVcs*(adapter: OriginAdapter, ctx: OriginContext): bool =
  adapter.isVcs(ctx)
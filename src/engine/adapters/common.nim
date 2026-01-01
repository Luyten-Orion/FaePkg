import std/[
  options,
  tables
]

from std/sugar import `->`

import pkg/parsetoml

import logging
import engine/faever


type
  OriginContext* = object
    targetDir*: string
    logCtx*: LoggerContext

  OriginAdapter* = object
    cloneImpl*: (ctx: OriginContext, url: string) -> bool
    fetchRefrImpl*: (ctx: OriginContext, url: string, refr: string) -> bool
    fetchTagsImpl*: (ctx: OriginContext, url: string) -> bool
    resolveImpl*: (ctx: OriginContext, refr: string) -> Option[string]
    pseudoversionImpl*: (ctx: OriginContext, refr: string) -> Option[tuple[ver: FaeVer, isPseudo: bool]]
    checkoutImpl*: (ctx: OriginContext, refr: string) -> bool
    catFileImpl*: (ctx: OriginContext, refr: string, file: string) -> Option[string]
    lsFileImpl*: (ctx: OriginContext, refr: string, pattern: string) -> seq[string]
    isVcs*: (ctx: OriginContext) -> bool

# Populated at startup, should never be modified afterwards... Can't enforce
# that though
var origins*: Table[string, OriginAdapter]
# TODO: Could potentially implement a 'foreign' adapter, that we search for on
# fae's startup? Similar to how shit like cargo works, when adding custom tools


proc init*(
  T: typedesc[OriginContext],
  targetDir: string,
  logCtx: LoggerContext
): T =
  T(targetDir: targetDir, logCtx: logCtx.with("origin"))


proc clone*(adapter: OriginAdapter, ctx: OriginContext, url: string): bool =
  adapter.cloneImpl(ctx, url)


proc fetch*(adapter: OriginAdapter, ctx: OriginContext, url, refr: string): bool =
  adapter.fetchRefrImpl(ctx, url, refr)


proc fetch*(adapter: OriginAdapter, ctx: OriginContext, url: string): bool =
  adapter.fetchTagsImpl(ctx, url)


proc resolve*(adapter: OriginAdapter, ctx: OriginContext, refr: string): Option[string] =
  adapter.resolveImpl(ctx, refr)


# TODO: Look at breaking this up into smaller functions...
proc pseudoversion*(
  adapter: OriginAdapter,
  ctx: OriginContext,
  refr: string
): Option[tuple[ver: FaeVer, isPseudo: bool]] =
  ## NOTE: This is for git specifically, it may vary from adapter to adapter.
  ## Creates a pseudoversion using the given reference, usually the tag
  ## preceding a commit. Format:
  ## `vX.Y.Z-[prerelease.]<commit date>.<commit hash (12 chars)>`
  adapter.pseudoversionImpl(ctx, refr)


proc checkout*(adapter: OriginAdapter, ctx: OriginContext, refr: string): bool =
  adapter.checkoutImpl(ctx, refr)


proc catFile*(adapter: OriginAdapter, ctx: OriginContext, refr: string, file: string): Option[string] =
  adapter.catFileImpl(ctx, refr, file)


proc lsFile*(adapter: OriginAdapter, ctx: OriginContext, refr, pattern: string): seq[string] =
  adapter.lsFileImpl(ctx, refr, pattern)


proc isVcs*(adapter: OriginAdapter, ctx: OriginContext): bool =
  adapter.isVcs(ctx)
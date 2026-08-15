when not isMainModule: {.error: "You should never import this file!".}

import std/[os, sugar, options, strutils, sequtils, strformat]
import experimental/cmdline
import faepkg/logging
import faepkg/logic/pipeline

proc validatePkgName(s: string) =
  let p = s.rsplit('/', 2)

  if p.len == 2:
    if p[0] == "":
      raise newException(ValueError, "Slashes must not be the first character!")
    for c in p[0].toOpenArray(1, p[0].high):
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '\x80'..'\xFF', '_', '/', '.'}:
        raise newException(ValueError, "Package name must only contain letters, numbers, slashes, dots, and underscores")

  if p[^1].len == 0:
    raise newException(ValueError, "Can't have an empty package name!")
  if p[^1].len == 1:
      if s[0] notin {'a'..'z', 'A'..'Z', '\x80'..'\xFF'}:
        raise newException(ValueError, "Package name cannot start with a number!")
  if p[^1].toLowerAscii in ["std", "stdlib", "unknown", "project-local"]:
    raise newException(ValueError, &"Package name cannot be `{s.toLowerAscii}` as that is a reserved name")

  for c in p[^1]:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '\x80'..'\xFF', '_'}:
      raise newException(ValueError, "Package name must only contain letters, numbers and underscores")

type
  Operation = enum
    opSync
    opInit

  Config = object
    case op: Operation
    of opSync:
      syncDir: string
    of opInit:
      packageName: string
      targetDir: Option[string]

proc handleSync(syncDir: string, logCtx: LoggerContext) =
  let logCtx = logCtx.with("pkg-sync")
  executeSync(syncDir, logCtx)

proc handleInit(name: string, targetDir: Option[string], logCtx: LoggerContext) =
  let logCtx = logCtx.with("pkg-init")
  try:
    validatePkgName(name)
  except ValueError as e:
    logCtx.error(&"Invalid package name `{name}`: {e.msg}")
    quit(1)

  let
    shortPkgName = name.rsplit('/', 2)[^1]
    pkgDir = targetDir.get(shortPkgName)
    path = pkgDir / "package.skull.toml"

  if toSeq(walkDir(pkgDir, relative=true)).len > 0:
    logCtx.error("Target directory is not empty!")
    quit(1)
  createDir(pkgDir)

  let manifest = &"""format = 0

[package]
name = "{name}"

#[dependencies.foo]
#src = "https://example.forge/foo/bar.git"
#version = "x.y.z" #OR refr = "taghere"
#foreign-pm = "nimble" #IF NIMBLE
"""
  try:
    writeFile(path, manifest)
    logCtx.info("Initialized new package manifest: " & name)
  except CatchableError as e:
    logCtx.error("Failed to write manifest: " & e.msg)
    quit(1)

  try:
    createDir(pkgDir / "src")
    writeFile(pkgDir / "src/lib.nim", &"""# This is the entrypoint for your package. `export` logic should go here ideally.
import {shortPkgName}/foo

export foo""")

    writeFile(pkgDir / "src/foo.nim", "proc bar*() = discard\nproc baz*() = discard")
  except CatchableError as e:
    logCtx.error("Failed to create src directory: " & e.msg)
    quit(1)

  # Initial setup
  handleSync(pkgDir, logCtx)

proc main() =
  var logger = Logger.new()
  logger.addCallback(LogCallback.init(
    consoleLogger(showStack=false), @[filterLogLevel(llInfo)]
  ))

  let logCtx = logger.with("fae-cli")

  var cli = commandBuilder(Config)
    .name("faepkg")
    .describe("Fae Package Manager")
    .initCli()

  cli.addHelpFlag(RootCommand, "help", "h")

  # --- Sync Subcommand ---
  let syncCmd = cli.commandBuilder()
    .name("sync")
    .describe("Synchronize dependencies and generate index")
    .parser((_, var cfg) => (cfg = Config(op: opSync, syncDir: getCurrentDir())))
    .addTo(cli, RootCommand)

  cli.positionalBuilder()
    .name("target-dir")
    .optional()
    .describe("The directory to sync")
    .parser(string, (val, var cfg) => (cfg.syncDir = val))
    .addTo(cli, syncCmd)

  cli.addHelpFlag(syncCmd)

  # --- Init Subcommand ---
  let initCmd = cli.commandBuilder()
    .name("init")
    .describe("Initialize a new package.skull.toml")
    .parser((_, var cfg) => (cfg = Config(op: opInit, targetDir: none(string))))
    .addTo(cli, RootCommand)

  cli.positionalBuilder()
    .name("name")
    .describe("The URI-based name of the package (e.g., forge.tld/user/pkg, yourdomain.tld/pkg)")
    .parser(string, (val, var cfg) => (cfg.packageName = val))
    .addTo(cli, initCmd)

  cli.positionalBuilder()
    .name("target-dir")
    .optional()
    .describe("The directory to create the package in")
    .parser(string, (val, var cfg) => (cfg.targetDir = some(val)))
    .addTo(cli, initCmd)

  cli.addHelpFlag(initCmd)

  # --- Execution ---
  let config = cli.run()

  case config.op
  of opSync:
    handleSync(config.syncDir, logCtx)
  of opInit:
    if config.packageName == "":
      logCtx.error("A package name is required for initialization.")
      quit(1)
    handleInit(config.packageName, config.targetDir, logCtx)

main()

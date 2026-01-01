when not isMainModule: {.error: "You should never import this file, fuck off!".}

import std/[
  strutils,
  random,
  sugar,
  os
]
import experimental/cmdline

import pkg/parsetoml

import logging

import engine/[
  faever,
  schema,
  lock,
  resolution
]
import engine/adapters/[
  common,
  git
]


import cli/cmds

randomize()

var cli = FaeArgs.commandBuilder()
  .name("fae")
  .describe("An elegant package manager for Nimskull!")
  .initCli()

cli.addHelpFlag()

cli.flagBuilder()
  .name("skull-path")
  .describe("Path to the skull binary we gotta invoke.")
  .parser(string, (opt, val, var args) => (args.skullPath = val))
  .addTo(cli)

cli.flagBuilder()
  .name("path")
  .alias("p")
  .describe("Path to the directory of the Fae project/workspace (default: .)")
  .parser(string, (opt, val, var args) => (args.projPath = val))
  .addTo(cli)


cli.flagBuilder()
  .name("log-level")
  .alias("l")
  .describe("Set the log level (default: info)")
  .parser(string, (opt, val, var args) => (
    try:
      args.logLevel = parseEnum[LogLevel](val.toUpperAscii())
    except ValueError:
      const ValidLogLevels = ["trace", "debug", "info", "warn", "error"]
        .join("`, `")

      quit(
        "Invalid log level `$1`, expected one of `$2`" % [val, ValidLogLevels],
        1
      )
  ))
  .addTo(cli)


let syncCmd = cli.commandBuilder()
  .name("sync")
  .describe("Synchronises the project state with the lockfile (or manifest as a fallback).")
  .parser((_, var args) => (args.kind = fkSync))
  .addTo(cli, RootCommand)


var args = cli.run(
  commandLineParams(), defaults=FaeArgs(
    projPath: getCurrentDir(),
    logLevel: llInfo
  )
)


case args.kind
  of fkNone:
    echo cli.help(RootCommand)
  of fkSync:
    syncCmd(args)
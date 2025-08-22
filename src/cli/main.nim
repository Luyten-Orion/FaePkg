when not isMainModule: {.error: "You should never import this file, bug off!".}
# TODO: Fae's commandline interface

import std/[
  sugar,
  os
]
import experimental/cmdline

import parsetoml

import ../engine/[
  faever,
  schema,
  lock,
  resolution
]
import ../engine/adapters/[
  common,
  git
]
import ../engine/private/tomlhelpers


import "."/[
  cmds
]


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


let grabCmd = cli.commandBuilder()
  .name("grab")
  .describe("Fetch all of the current project/workspace's dependencies.")
  .parser((_, var args) => (args.kind = fkGrab))
  .addTo(cli, RootCommand)


var args = cli.run(commandLineParams(), defaults=FaeArgs(
  projPath: getCurrentDir())
)


case args.kind
  of fkNone:
    echo cli.help(RootCommand)
  of fkGrab:
    grabCmd(args)
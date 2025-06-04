import std/[
  # For string splitting (mostly on paths)
  strutils,
  # For passing a custom environment to the `startProcess` function
  strtabs,
  # For key-table mappings, such as the `repoToLoc` field
  tables,
  # For `startProcess` (cloning/fetching from git)
  osproc,
  # Used for URI handling
  uri,
  # Used for path handling
  os
]


var
  queued, succeded: seq[string]
  repoToLoc: Table[string, string]
  processes: Table[string, Process]


for dep in dependencies:
  var repoLoc = ".fae" / "deps" / dep.src.path.split("/")[^1]

  if repoLoc.endsWith(".git"): repoLoc = repoLoc[0..^5]

  queued.add $dep.src
  repoToLoc[$dep.src] = repoLoc


proc git(op, repo, loc: string): Process =
  let
    env {.global.} = {"GIT_TERMINAL_PROMPT": "0"}.newStringTable
    gitBin {.global.} = findExe("git")


  if op == "clone":
    startProcess(gitBin, args = [op, repo, loc], env = env)
  elif op == "fetch":
    startProcess(gitBin, loc, args = [op], env = env)
  else:
    raise newException(ValueError, "Unknown operation: " & op)


proc getOp(p: string): string =
  if p.dirExists:
    return "fetch"
  else:
    return "clone"


let count = queued.len

while succeded.len < count:
  if processes.len < 4 and queued.len > 0:
    let
      repo = queued.pop
      loc = repoToLoc[repo]
      word =
        if getOp(loc) == "clone":
          "Cloning "
        else:
          "Fetching "

    processes[repo] = git(getOp(loc), repo, loc)
    echo word, repo

  for process in toSeq(processes.keys):
    if processes[process].peekExitCode == 0:
      succeded.add process
      let word =
        if getOp(repoToLoc[process]) == "clone":
          "cloned "
        else:
          "fetched "
      echo "Successfully ", word, process
      processes[process].close()
      processes.del(process)

      if queued.len > 0:
        let
          repo = queued.pop
          loc = repoToLoc[repo]

        processes[repo] = git(getOp(loc), repo, loc)
        let word =
          if getOp(loc) == "clone":
            "Cloning "
          else:
            "Fetching "

        echo word, repo

    elif processes[process].peekExitCode == -1: continue

    else:
      let word =
        if getOp(process) == "clone":
          "clone "
        else:
          "fetch "
      echo "Failed to ", word, process, ", exited with code ",
        processes[process].peekExitCode

  sleep 1000
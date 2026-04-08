when not isMainModule: {.error: "You should never import this file!".}

import std/[os]
import faepkg/logging
import faepkg/logic/pipeline

# (Assuming your experimental/cmdline code remains here...)

proc main() =
  var logger = Logger.new()
  # Default setup for skeleton
  logger.addCallback(LogCallback.init(
    consoleLogger(showStack=false), @[filterLogLevel(llInfo)]
  ))
  
  let logCtx = logger.with("fae-cli")
  let currentPath = getCurrentDir()
  
  executeSync(currentPath, logCtx)

main()
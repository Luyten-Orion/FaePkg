import std/[os, osproc, json, strutils]

let
  currentDir = getCurrentDir()
  skullDir = currentDir / ".skull"
  tmpDir = getTempDir() / "faepkg_bootstrap"
  parsetomlDir = tmpDir / "parsetoml"

createDir(tmpDir)

if not dirExists(parsetomlDir):
  let res = execCmd("git clone https://github.com/nimparsers/parsetoml.git -b v0.7.2 " & quoteShell(parsetomlDir))
  if res != 0:
    quit("Cannot continue, unable to clone parsetoml!", res)

# 2. Create the .skull directory
createDir(skullDir)

# Cross-platform path formatting for the index.json
template toUnixPath(p: string): string =
  when defined(windows): p.replace('\\', '/') else: p

let
  parsetomlPath = toUnixPath(parsetomlDir)
  rootPath = toUnixPath(currentDir)

# 3. Forge the minimal index.json
# We manually apply the Nimble path offsets (srcDir / entrypoint) 
# so Nimskull knows exactly how to import it during the initial compile.
let indexJson = %*{
  "packages": {
    "github.com/nimparsers/parsetoml@0.7.2": {
      "path": parsetomlPath,
      "srcDir": "src/parsetoml",
      "entrypoint": "../parsetoml.nim",
      "dependencies": [
        {
          "package": "github.com/nimparsers/parsetoml@0.7.2",
          "alias": "parsetoml"
        }
      ]
    },
    "faepkg": {
      "path": rootPath,
      "srcDir": "src",
      "entrypoint": "lib.nim",
      "dependencies": [
        {
          "package": "github.com/nimparsers/parsetoml@0.7.2",
          "alias": "parsetoml"
        },
        {
          "package": "faepkg",
          "alias": "faepkg"
        }
      ]
    }
  }
}

writeFile(skullDir / "index.json", indexJson.pretty())

quit(execCmd("nim r src/cli/main.nim sync"))
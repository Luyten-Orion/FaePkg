# FaePkg
FaePkg, the revolutionary package manager for Nim(skull)!

This exists as a learning experience and a serious attempt at making a package
manager that I personally would enjoy to use, unlike Nimble which sometimes
feels a bit more painful than it should be...

## Thoughts
This will definitely require some modifications to the compiler to allow for
cleaner integration, right now the goal is to get a clean package manager

## To-Dos
- [ ] Implement manifest parsing and validation
- [ ] Implement origin adapters
  - [x] Implement `git` adapter
  - [ ] Maybe implement `hg` adapter
- [x] Implement dependency resolution
  - [x] Gathering stage
  - [x] Resolution stage
  - [x] Download stage
  - Repeat to completion.
- [ ] Implement `foreign-pm = "nimble"` support.

### Potential To-Dos
- [ ] Expose a public API. Not sure what it should consist of yet.
- [ ] Add an accompanying buildsystem library.
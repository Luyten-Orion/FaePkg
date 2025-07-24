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
  - [ ] Implement `git` adapter
  - [ ] Implement `path` adapter (relative to project root)
  - [ ] Implement `local` hybrid adapter (for dependencies downloaded locally
      but do have an origin somewhere else, this is likely going to be used
      a lot in local development, when developing a library alongside an app)
  - [ ] Implement `nimble` hybrid adapter, it will be much more limited than
      fae-native packages, in terms of the features we can support, but we
      could potentially fill that gap using pseudo-package declarations?
      But honestly, it's probably not worth the effort to attempt 'clean'
      interop.
- [ ] Implement dependency resolution
  - [ ] Gathering stage
  - [ ] Resolution stage
  - [ ] Download stage
  - Repeat to completion.

### Potential To-Dos
- [ ] Expose a public API. Not sure what it should consist of yet.
- [ ] Add an accompanying buildsystem library.
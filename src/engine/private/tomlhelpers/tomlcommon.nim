import std/[
  macros
]


# Some pragmas for making deserialisation cleaner
template rename*(name: string) {.pragma.}
# TODO: Make `tag` work... basically, fix case object deserialisation
#template tag*(field: string, value: Ordinal) {.pragma.}
template ignore* {.pragma.}
template optional*[T: not void](default: T) {.pragma.}
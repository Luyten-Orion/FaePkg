# minimal.nimble
srcDir = "src"

# Single-line parentheses
requires("dummyA", "dummyB", "dummyC")

# Multi-line parentheses
requires(
  "dummyD",
  "dummyE",
  "dummyF"
)

# Space-separated single-line
requires "dummyG", "dummyH", "dummyI"

# Space-separated multi-line
requires "dummyJ",
  "dummyK",
  "dummyL"

# Array syntax
requires @["dummyM", "dummyN", "dummyO"]
requires ["dummyP", "dummyQ", "dummyR"]

# Mix of parentheses and array
requires(
  "dummyS",
  "dummyT",
  "dummyU"
)
requires @["dummyV", "dummyW", "dummyX"]
requires "dummyY", "dummyZ"
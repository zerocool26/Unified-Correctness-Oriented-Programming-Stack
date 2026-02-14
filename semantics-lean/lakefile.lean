import Lake
open Lake DSL

package semantics where
  moreServerOptions := #[]
  moreLeanArgs := #["-Dpp.unicode.fun=true"]

lean_lib Semantics where
  roots := #[`Main]

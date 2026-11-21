/-
rhv-replay: replay named modules through the Lean kernel, one after another, in one process.

`replayFromImports` below is copied without change from `src/lean/LeanChecker.lean` of the pinned toolchain
(Lean v4.33.1; copyright (c) 2023 Kim Morrison, Apache 2.0 licence; authors Kim Morrison, Sebastian Ullrich).
It is the function `leanchecker` runs for each module it checks: it loads the module's compiled file, builds
the environment of the module's imports, and adds each of the module's declarations to that environment again
through `Environment.replay`, which sends every one of them to the kernel.

What differs from `leanchecker` is only how the modules to check are chosen. `leanchecker` treats each argument
as a name prefix and, for each argument, lists every compiled file on the search path to find the modules that
match. On a tree of 175,187 modules that listing costs far more than the check itself, once per process. This
program takes exact module names, finds each compiled file directly (`findOLean`), and replays the modules in
the order given. Like `leanchecker`, it runs each replay in a task of its own and stops at the first module
that fails; unlike `leanchecker`, it waits for one replay to finish before starting the next.

Output, flushed line by line. For each module, in the order given:
  REPLAY_START <module>                                 before anything is done for the module
  REPLAY_OK <module> <milliseconds>                     the kernel accepted every declaration the module adds
  REPLAY_FAIL <module> <milliseconds> <the error, on one line>
The module is printed exactly as it was given. After a REPLAY_FAIL the program exits: a failed replay leaves
the imported files mapped, and `leanchecker` would have ended there too. Exit status: 0 if every module given
passed, 1 after the first failure, 2 for a usage error. The caller (scripts/verify/kernel_check_batch.sh)
records each result as it arrives, charges a death in mid-replay to the module whose REPLAY_START was the last
line, and starts a new process for whatever is left.

Usage: rhv-replay MODULE...        or        rhv-replay --list FILE   (one module name per line)
-/
import Lean.CoreM
import Lean.Replay

open Lean

unsafe def replayFromImports (module : Name) : IO Unit := do
  let mFile ← findOLean module
  unless (← mFile.pathExists) do
    throw <| IO.userError s!"object file '{mFile}' of module {module} does not exist"
  -- Load all module data parts (exported, server, private)
  let mut fnames := #[mFile]
  let sFile := OLeanLevel.server.adjustFileName mFile
  if (← sFile.pathExists) then
    fnames := fnames.push sFile
    let pFile := OLeanLevel.private.adjustFileName mFile
    if (← pFile.pathExists) then
      fnames := fnames.push pFile
  let parts ← readModuleDataParts fnames
  if h : parts.size = 0 then throw <| IO.userError "failed to read module data" else
  let (mod, _) := parts[0]
  let (_, s) ← importModulesCore mod.imports |>.run
  let env ← finalizeImport s mod.imports {} 0 false false (isModule := true)
  let mut newConstants := {}
  -- Collect constants from last ("most private") part, which subsumes all prior ones
  for name in parts[parts.size-1].1.constNames, ci in parts[parts.size-1].1.constants do
    newConstants := newConstants.insert name ci
  let env' ← env.replay newConstants
  env'.freeRegions

unsafe def main (args : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  let names ← match args with
    | ["--list", file] => pure ((← IO.FS.lines file).toList.filter (· ≠ ""))
    | _ => pure args
  if names.isEmpty || names.any (·.startsWith "-") then
    IO.eprintln "usage: rhv-replay MODULE...   or   rhv-replay --list FILE"
    return 2
  let out ← IO.getStdout
  for arg in names do
    out.putStrLn s!"REPLAY_START {arg}"
    out.flush
    let module := arg.toName
    let t0 ← IO.monoMsNow
    if module.isAnonymous then
      out.putStrLn s!"REPLAY_FAIL {arg} 0 not a module name"
      out.flush
      return 1
    let task ← IO.asTask (replayFromImports module)
    match task.get with
    | .ok _ =>
      out.putStrLn s!"REPLAY_OK {arg} {(← IO.monoMsNow) - t0}"
      out.flush
    | .error e =>
      out.putStrLn s!"REPLAY_FAIL {arg} {(← IO.monoMsNow) - t0} {(toString e).replace "\n" " | "}"
      out.flush
      return 1
  return 0

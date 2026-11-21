import Lean
/-!
# Axiom and statement check (body)

`scripts/08_check_axioms.sh` builds the file it runs by writing one `import` line for the module
under test, appending this file unchanged, and appending a footer that runs `#print axioms` on
each theorem and then calls `RHVerifyCheck.run`.

Everything defined here lives in the check file itself. Nothing is added to, or changed in, the
modules under test. All output lines that start with `RHV ` are read by
`scripts/verify/rhv_tools.py axioms-summary`, which decides pass or fail; this file only reports.

Two different sources of axiom information are used, and they should not be confused.

* `Lean.collectAxioms` is the function behind `#print axioms`. In Lean v4.33.1, for a
  declaration that comes from an imported module, it returns the axiom list that the compiler
  recorded in that module's compiled file when the file was written. It does not walk proof terms
  across module boundaries. Its answer is as trustworthy as the compiled files.
* `deepWalk` (used only with `--deep`) ignores those records. It starts from the theorems and
  visits every constant reachable through types, values and constructors, as stored in the loaded
  environment, and lists every constant that is an axiom. It also counts, for each module, how
  many of that module's constants it visited. Those counts decide nothing; they are reported as
  `RHV DEEP_MODULE` lines so that a reader can see which modules the theorems actually rest on.
-/
open Lean Elab Command

namespace RHVerifyCheck

/-- The three axioms of Lean's standard classical foundations. -/
def allowedAxioms : List Name := [`propext, `Classical.choice, `Quot.sound]

/-- First components of module names that belong to Lean, Mathlib or Mathlib's dependencies.
Any other module is treated as part of the project under test. -/
def libraryRoots : List Name :=
  [`Init, `Std, `Lean, `Lake, `Mathlib, `Batteries, `Aesop, `Qq, `ProofWidgets, `Plausible,
    `ImportGraph, `LeanSearchClient, `Cli]

/-- Name of the module that declares `n`. -/
def moduleOf (env : Environment) (n : Name) : String :=
  match env.getModuleIdxFor? n with
  | some i => toString (env.header.moduleNames[i.toNat]!)
  | none => "(not-imported)"

def isLibraryConst (env : Environment) (n : Name) : Bool :=
  match env.getModuleIdxFor? n with
  | some i => libraryRoots.contains (env.header.moduleNames[i.toNat]!).getRoot
  | none => false

def kindOf : ConstantInfo → String
  | .axiomInfo _ => "axiom"
  | .defnInfo _ => "definition"
  | .thmInfo _ => "theorem"
  | .opaqueInfo _ => "opaque"
  | .quotInfo _ => "quot"
  | .inductInfo _ => "inductive"
  | .ctorInfo _ => "constructor"
  | .recInfo _ => "recursor"

/-- Whether `c` is an axiom, and the constants its declaration refers to. `none` if `c` is not
in the environment. -/
def constantsUsedBy (env : Environment) (c : Name) : Option (Bool × Array Name) :=
  match env.find? c with
  | none => none
  | some (.axiomInfo v) => some (true, v.type.getUsedConstants)
  | some (.defnInfo v) => some (false, v.type.getUsedConstants ++ v.value.getUsedConstants)
  | some (.thmInfo v) => some (false, v.type.getUsedConstants ++ v.value.getUsedConstants)
  | some (.opaqueInfo v) => some (false, v.type.getUsedConstants ++ v.value.getUsedConstants)
  | some (.quotInfo v) => some (false, v.type.getUsedConstants)
  | some (.ctorInfo v) => some (false, v.type.getUsedConstants)
  | some (.recInfo v) => some (false, v.type.getUsedConstants)
  | some (.inductInfo v) => some (false, v.type.getUsedConstants ++ v.ctors.toArray)

/-- Visit every constant reachable from `roots`. Returns the axioms found, the names that were
referred to but are not in the environment, the number of constants visited, and, indexed like
`env.header.moduleNames`, how many of each module's constants were visited. Uses an explicit
stack, so the depth of the dependency chain does not matter. -/
def deepWalk (env : Environment) (roots : List Name) :
    Array Name × Array Name × Nat × Array Nat := Id.run do
  let mut visited : NameSet := {}
  let mut stack : Array Name := roots.toArray
  let mut axioms : Array Name := #[]
  let mut missing : Array Name := #[]
  let mut count : Nat := 0
  let mut perModule : Array Nat := Array.replicate env.header.moduleNames.size 0
  while !stack.isEmpty do
    let c := stack.back!
    stack := stack.pop
    if visited.contains c then
      continue
    visited := visited.insert c
    count := count + 1
    if let some i := env.getModuleIdxFor? c then
      perModule := perModule.modify i.toNat (· + 1)
    match constantsUsedBy env c with
    | none => missing := missing.push c
    | some (isAxiom, used) =>
      if isAxiom then
        axioms := axioms.push c
      for u in used do
        unless visited.contains u do
          stack := stack.push u
  return (axioms, missing, count, perModule)

/-- Kind, declaring module, axioms (from `Lean.collectAxioms`) and type of one theorem. -/
def reportTheorem (n : Name) : CommandElabM Unit := do
  let env ← getEnv
  match env.find? n with
  | none => logInfo m!"RHV MISSING {n}"
  | some ci =>
    logInfo m!"RHV KIND {n} {kindOf ci}"
    logInfo m!"RHV DECLARED_IN {n} {moduleOf env n}"
    let axs ← collectAxioms n
    logInfo m!"RHV AXIOM_COUNT {n} {axs.size}"
    for a in axs do
      logInfo m!"RHV AXIOM {n} {a}"
    logInfo m!"RHV TYPE_BEGIN {n}\n{ci.type}\nRHV TYPE_END {n}"

/-- The constants that the statement (type) of `thm` refers to. Constants declared by the project
are followed into their own types, values and constructors, and printed with their definitions;
library constants are listed but not followed. -/
def reportStatement (thm : Name) : CommandElabM Unit := do
  let env ← getEnv
  let some ci := env.find? thm | return
  let mut seen : NameSet := {}
  let mut todo : Array Name := ci.type.getUsedConstants
  let mut library : Array Name := #[]
  let mut project : Array Name := #[]
  while !todo.isEmpty do
    let c := todo.back!
    todo := todo.pop
    if seen.contains c then
      continue
    seen := seen.insert c
    if isLibraryConst env c then
      library := library.push c
    else
      project := project.push c
      match constantsUsedBy env c with
      | some (_, used) => todo := todo ++ used
      | none => pure ()
  logInfo m!"RHV STATEMENT_PROJECT_COUNT {thm} {project.size}"
  for c in project do
    logInfo m!"RHV STATEMENT_PROJECT_CONST {thm} {c} {moduleOf env c}"
    match env.find? c with
    | some d =>
      match d.value? with
      | some v => logInfo m!"RHV PROJECT_DEF_BEGIN {c}\n{v}\nRHV PROJECT_DEF_END {c}"
      | none => logInfo m!"RHV PROJECT_DEF_NONE {c} {kindOf d}"
    | none => logInfo m!"RHV PROJECT_DEF_NONE {c} missing"
  logInfo m!"RHV STATEMENT_LIBRARY_COUNT {thm} {library.size}"
  for c in library do
    logInfo m!"RHV STATEMENT_LIBRARY_CONST {thm} {c} {moduleOf env c}"

/-- Entry point. `mode` is `full` or `probe`. In `probe` mode the primary theorem is allowed to
have hypotheses and the check is on its conclusion. -/
def run (mode : String) (deep : Bool) (primary : Name) (theorems : List Name) :
    CommandElabM Unit := do
  let env ← getEnv
  logInfo m!"RHV LEAN_VERSION {Lean.versionString}"
  logInfo m!"RHV MODE {mode}"
  for a in allowedAxioms do
    logInfo m!"RHV ALLOWED {a}"
  for t in theorems do
    reportTheorem t
    reportStatement t
  match env.find? primary with
  | none => logInfo m!"RHV MISSING {primary}"
  | some ci =>
    let target := if mode == "probe" then ci.type.getForallBody else ci.type
    let isRH : Bool := target == mkConst `RiemannHypothesis
    logInfo m!"RHV CHECK statement_is_constant_RiemannHypothesis {primary} {isRH}"
  for c in [`RiemannHypothesis, `riemannZeta, `DirichletCharacter.LFunction] do
    match env.find? c with
    | none => logInfo m!"RHV MISSING_CONST {c}"
    | some d =>
      logInfo m!"RHV MODULE {c} {moduleOf env c}"
      if c == `RiemannHypothesis then
        match d.value? with
        | some v => logInfo m!"RHV DEF_BEGIN {c}\n{v}\nRHV DEF_END {c}"
        | none => logInfo m!"RHV DEF_NONE {c} {kindOf d}"
  if deep then
    let (axs, missing, count, perModule) := deepWalk env theorems
    logInfo m!"RHV DEEP_VISITED {count}"
    logInfo m!"RHV DEEP_AXIOM_COUNT {axs.size}"
    for a in axs do
      logInfo m!"RHV DEEP_AXIOM {a} {moduleOf env a}"
    logInfo m!"RHV DEEP_MISSING_COUNT {missing.size}"
    for c in missing do
      logInfo m!"RHV DEEP_MISSING {c}"
    -- Which modules the walk touched: L for a library module, P for a module of the project.
    let names := env.header.moduleNames
    let mut lines : Array String := #[]
    for i in [0:names.size] do
      let k := perModule[i]!
      if k > 0 then
        let m := names[i]!
        let tag := if libraryRoots.contains m.getRoot then "L" else "P"
        lines := lines.push s!"RHV DEEP_MODULE {tag} {m} {k}"
    logInfo m!"RHV DEEP_MODULE_COUNT {lines.size}"
    if !lines.isEmpty then
      logInfo m!"{String.intercalate "\n" lines.toList}"
  logInfo m!"RHV DONE"

end RHVerifyCheck

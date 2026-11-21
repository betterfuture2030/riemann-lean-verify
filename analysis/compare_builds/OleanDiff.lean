/-
OleanDiff: compare two compiled files of the same module by content, not by bytes.

For each pair it reads both files as module data and compares: the imports; the names of the constants and
their order; and, for each constant, its kind, its universe parameters, its type and its value (the proof
term, for a theorem), by structural equality of the expressions. It also says whether the two files carry the
same number of entries for each environment extension; it does not compare those entries.

What it changes on disk: nothing. How long it takes: well under a second per pair for small modules.

Usage: lean --run OleanDiff.lean PAIRS     (PAIRS: lines "module<TAB>fileA<TAB>fileB", as compare_builds.py --pairs writes)
       Run it from a directory whose lean-toolchain is the project's, so that the pinned Lean reads the files.
Output, one line per pair:  module <TAB> SAME_CONSTANTS | DIFFERENT | ERROR <TAB> detail
-/
import Lean
open Lean

def kindOf : ConstantInfo → String
  | .axiomInfo _ => "axiom" | .defnInfo _ => "def" | .thmInfo _ => "thm" | .opaqueInfo _ => "opaque"
  | .quotInfo _ => "quot" | .inductInfo _ => "induct" | .ctorInfo _ => "ctor" | .recInfo _ => "rec"

unsafe def compareOne (mod a b : String) : IO String := do
  let (da, ra) ← readModuleData a
  let (db, rb) ← readModuleData b
  let mut notes : Array String := #[]
  if da.imports.map (·.module) != db.imports.map (·.module) then notes := notes.push "imports differ"
  let na := da.constNames; let nb := db.constNames
  let sameOrder := na == nb
  let sa : Std.HashSet Name := Std.HashSet.ofArray na
  let sb : Std.HashSet Name := Std.HashSet.ofArray nb
  let onlyA := na.filter (!sb.contains ·)
  let onlyB := nb.filter (!sa.contains ·)
  if !onlyA.isEmpty || !onlyB.isEmpty then
    notes := notes.push s!"names differ: {onlyA.size} only in A (e.g. {onlyA[0]?}), {onlyB.size} only in B (e.g. {onlyB[0]?})"
  -- constants by name
  let mut mb : Std.HashMap Name ConstantInfo := {}
  for n in nb, c in db.constants do mb := mb.insert n c
  let mut typeDiff := 0; let mut valueDiff := 0; let mut kindDiff := 0; let mut lvlDiff := 0
  let mut firstDiff : Option Name := none
  for n in na, c in da.constants do
    if let some c' := mb[n]? then
      if kindOf c != kindOf c' then kindDiff := kindDiff + 1; if firstDiff.isNone then firstDiff := some n
      if c.levelParams != c'.levelParams then lvlDiff := lvlDiff + 1; if firstDiff.isNone then firstDiff := some n
      if !(c.type == c'.type) then typeDiff := typeDiff + 1; if firstDiff.isNone then firstDiff := some n
      match c.value? (allowOpaque := true), c'.value? (allowOpaque := true) with
      | some v, some v' => if !(v == v') then valueDiff := valueDiff + 1; if firstDiff.isNone then firstDiff := some n
      | none, none => pure ()
      | _, _ => valueDiff := valueDiff + 1; if firstDiff.isNone then firstDiff := some n
  if kindDiff + lvlDiff + typeDiff + valueDiff > 0 then
    notes := notes.push s!"constants differ: {typeDiff} types, {valueDiff} values, {kindDiff} kinds, {lvlDiff} level params (first: {firstDiff})"
  let entriesA := da.entries.map fun (n, es) => (n, es.size)
  let entriesB := db.entries.map fun (n, es) => (n, es.size)
  let extNote := if entriesA == entriesB then "extension entry counts equal" else "extension entry counts differ"
  let detail := s!"{na.size} constants; order {if sameOrder then "same" else "differs"}; {extNote}"
  ra.free; rb.free
  if notes.isEmpty then
    return s!"{mod}\tSAME_CONSTANTS\t{detail}"
  else
    return s!"{mod}\tDIFFERENT\t{detail}; {"; ".intercalate notes.toList}"

unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | [list] =>
    for line in (← IO.FS.lines list) do
      match line.splitOn "\t" with
      | [m, a, b] =>
        try IO.println (← compareOne m a b)
        catch e => IO.println s!"{m}\tERROR\t{(toString e).replace "\n" " | "}"
        (← IO.getStdout).flush
      | _ => pure ()
    return 0
  | _ =>
    IO.eprintln "usage: OleanDiff LIST"
    return 2

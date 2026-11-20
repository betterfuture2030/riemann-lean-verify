# riemann-lean-verify

An independent, reproducible check of a published Lean 4 formalization that claims to prove the Riemann Hypothesis.

The formalization is distributed as a source tarball from `alpo.ge`, together with a short announcement. It is about 175,000 Lean files and 17.4 million lines. This repository does not contain that source. Its tooling downloads it, checks it against a recorded SHA-256, inspects it before anything is executed, compiles it with the pinned Lean and Mathlib versions, and then runs the checks that decide whether the claimed theorem has actually been proved.

## Status

As of 2026-11-20: **not verified; compile in progress.** About 6 percent of the modules have compiled, with zero failures so far. That is not a verdict.

## Pre-registration

The criteria for calling the proof verified, and what will be reported under every other outcome, were fixed before the result was known. They are in [`PREREGISTRATION.md`](PREREGISTRATION.md), which was the first commit to this repository. It will not be edited; any change will be added as a dated amendment.

## What is coming

The following are being added in later commits, each reviewed before it lands:

- numbered scripts that reproduce every step on a Mac or Linux machine, and a calibration pilot for Google Cloud;
- a claims ledger giving, for every finding, the command that reproduces it and the expected result, so that the work can be reviewed or replicated by hand or with a basic coding agent;
- the records from the runs so far: hashes, expected values, timings and the source audit;
- a paper describing the method and the outcome.

## What this repository is not

It is not the proof and does not redistribute it. It is not affiliated with the proof's author. It is neither an endorsement nor a refutation.

## How this work is done

The investigation is carried out with substantial help from an AI coding assistant, directed and reviewed by the author, who is responsible for the content. Its conclusions are designed to rest only on checks that anyone can re-run without such a tool.

## Contact and licence

Questions and corrections: peter.lowes@sie.life, or open an issue.

The tooling and documentation here are under the MIT licence; see [`LICENSE`](LICENSE). The Lean formalization that this tooling downloads is a separate work by its own author.

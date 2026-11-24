# Where this work sits: what others have done

Written on 2026-11-23, when the author first read other people's results on this formalization. Until then the work here was blind ([`../README.md`](../README.md), "How this work is done"). Everything below was read from the pages linked, on that day; those pages are the record, and they will have moved on.

## The short version

By the time the run recorded in [`../records/cloud/full-run/`](../records/cloud/full-run/) finished, the formalization had already been checked by many people, with more machines and stronger methods than this repository uses. That run is one more confirmation of something already established. It is not news, and nothing here should be read as if it were.

What this repository may add is narrower: a measured, low-cost way of making such a check, written so that someone who is not a Lean expert can repeat it.

## What has been done

- **The Lean FRO and the Mathlib Initiative** published a joint statement on 2026-11-21 saying they have full confidence that the proof is correct: <https://leanprover-community.github.io/blog/posts/riemann-hypothesis/>. It says dozens of people had by then reported a correct compile.
- **Andrew Sutherland (MIT)** keeps the reference record of the checks, with logs and scripts: <https://math.mit.edu/~drew/grh/>. It covers the compile; the axioms; a `leanchecker` replay of every module; a rebuild in a sandbox with no network on a separate machine; an export of the proof by `lean4export` (61,570,595,788 bytes) that the sandboxed rebuild reproduced byte for byte; acceptance of that export by Lean's kernel and by independently written kernels (`nanoda`, `con-leche`, `con-ron`, `lean4lean`); and Comparator's check of the five statements against a challenge file that imports only Mathlib.
- **The community repository** <https://github.com/leanprover-community/riemann-hypothesis> holds the source, a Comparator setup and a build cache, and is working to make the proof cheaper to build and easier to read. It asks people not to send it claims about their own machine's builds.
- **Other independent checks** include one on the LUMI supercomputer (<https://github.com/aapolipponen/rh-lean-check-lumi>), which also documents the memory-mapping limit and the memory needed by deep modules, and <https://github.com/Hertaspace/alpoge-rh-lean-verification>.
- **The standard these follow** is set out in Kevin Buzzard's post of 2026-11-12, "…and the proof is checked in Lean" (<https://xenaproject.wordpress.com/2026/11/12/and-the-proof-is-checked-in-lean/>), and in the Lean reference, "Validating a Lean Proof" (<https://lean-lang.org/doc/reference/latest/ValidatingProofs/>).

None of this is about whether people understand the mathematics. That is a separate matter, and not one this repository can speak to.

## How the checks here compare

The Lean reference describes an escalating sequence of checks. The pre-registered criteria of this repository reach the third of its four levels.

| Check | The community's record | This repository |
|---|---|---|
| The whole tree compiles | Yes | Yes (C1) |
| `#print axioms`, and a walk of everything the theorems depend on | Yes | Yes (C2) |
| Kernel replay of every compiled module by `leanchecker` | Yes | Yes (C3) |
| The statements compared with a challenge file that imports only Mathlib (Comparator) | Yes, by two tools | In part, since 2026-11-24: `con-leche --compare` on the community's challenge file reported all five theorems justified. `lake comparator` itself has not been run |
| The build made in a sandbox with no network | Yes | No. The cloud run used a dedicated build user on a machine made for the run and deleted after it |
| An export of the proof, checked outside the build | Yes | Yes, since 2026-11-24: the export of the cloud run's compiled files is byte for byte the published one (61,570,595,788 bytes, SHA-256 `5ea74b91…244e`) |
| A second, independently written kernel | Several, two of them formally verified | One: `con-leche` accepted all 1,468,418 declarations of the export. `nanoda` was attempted and not run correctly |

The last four rows are the difference between "re-checked by Lean's own kernel" and what the Lean reference calls the gold standard. When this page was first written this repository had none of them. The export check of 2026-11-24 ([`../records/cloud/export-check/`](../records/cloud/export-check/)) added two and part of a third, using the community's challenge file, targets, exporter and kernel. Still missing: `lake comparator` end to end, which also runs Lean's own kernel over the export; a sandboxed build; and a second independent kernel.

## Where the results agree

Five things in the record here can be compared with what others published, and each agrees:

- the source archive has SHA-256 `9631b4f0…49c7fc`, as on Sutherland's page;
- the compiled `Main.olean` and `Statements.olean` of the cloud run have SHA-256 `9146dfb4…96ad` and `f8e0aed3…d6b1`, the values Sutherland and the LUMI check give (most other compiled files embed the build directory's path and cannot be compared across machines);
- the export of the challenge file has SHA-256 `bd484ac9…b2b9` and the export of the proof `5ea74b91…244e`, the values on Sutherland's page; this is the strongest of the five, since it covers every declaration the five theorems rest on;
- the walk of everything the five theorems depend on visited 1,478,243 constants, the figure the LUMI check reports and says it shares with a third, independent count.

## What may be useful here

- **Cost.** The published builds used large machines (192 cores, 480 cores, a supercomputer). The run here used one 32-vCPU machine at Spot prices, was interrupted once by the provider and carried on, and is recorded at about 26 USD of machine time at work ([`cloud-notes.md`](cloud-notes.md), section 10.8).
- **The export and an independent kernel on a small machine.** From compiled files already in hand, the export and two runs of `con-leche` took 2.2 hours and 4.49 USD on one 32-vCPU machine; the export is single-threaded and took 95 minutes of that, and `con-leche` under eight minutes a run with a peak of 45 GiB.
- **A laptop.** A build on a 24 GB Mac is in progress, with what it took to keep it within memory written down ([`performance-notes.md`](performance-notes.md)). No finished laptop build had been found in what was read on 2026-11-23.
- **The replay.** Run once per module with the whole library on its search path, `leanchecker` slows as the tree grows; given only each module's imports it replayed the tree in 7.2 hours on 32 vCPUs ([`performance-notes.md`](performance-notes.md), section 10).
- **Scripts that need no AI tool and little Lean.** Each step is a shell script that says what it does and what it changes.

Whether any of this is new to the people who did the work above is not known: the main discussion, on the Lean Zulip, had not been read when this was written.

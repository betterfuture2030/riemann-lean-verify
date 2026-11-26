# Where this work sits: what others have done

Written on 2026-11-23, when the author first read other people's results on this formalization, and brought up to date on 2026-11-26. Until the first of those dates the work here was blind ([`../README.md`](../README.md), "How this work is done"). Everything below was read from the pages linked, on one of those two days; those pages are the record, and they will have moved on.

## The short version

By the time the run recorded in [`../records/cloud/full-run/`](../records/cloud/full-run/) finished, the formalization had already been checked by many people, with more machines and stronger methods than this repository uses. That run is one more confirmation of something already established. It is not news, and nothing here should be read as if it were.

What this repository may add is narrower: a measured, low-cost way of making such a check, written so that someone who is not a Lean expert can repeat it.

## What has been done

- **The Lean FRO and the Mathlib Initiative** published a joint statement on 2026-11-21 saying they have full confidence that the proof is correct: <https://leanprover-community.github.io/blog/posts/riemann-hypothesis/>. It says dozens of people had by then reported a correct compile.
- **Andrew Sutherland (MIT)** keeps the reference record of the checks, with logs and scripts: <https://math.mit.edu/~drew/grh/>. It covers the compile; the axioms; a `leanchecker` replay of every module; a rebuild in a sandbox with no network on a separate machine; an export of the proof by `lean4export` (61,570,595,788 bytes) that the sandboxed rebuild reproduced byte for byte; acceptance of that export by Lean's kernel, by the independently written kernels `nanoda` and `con-leche`, and by `con-ron`, a port of `con-leche` to Rust; acceptance of every compiled module by `lean4lean`; and Comparator's check of the five statements against a challenge file that imports only Mathlib.
- **That record was complete by 2026-11-25.** Its last long check, `lake comparator` (Lean v4.36.0) run on the two exports with the community's configuration, ended that day after 122 hours 45 minutes with "Your solution is okay!", the paranoid kernel, `nanoda` and Lean's default kernel each having accepted the export inside it.
- **A much shorter proof of the same five theorems was published on 2026-11-25**, at <https://github.com/lsernau/grh-lean>; its README describes it as a shorter version of the original. It has about 800 files and 300,000 lines in one edition and 76,000 lines in another, against 175,187 files and 17.4 million lines. Sutherland's page for it (<https://math.mit.edu/~drew/shortgrh/>) records a sandboxed build in 32 minutes on a 16-core machine with 128 GB, and its checks, `lake comparator --paranoid` among them, finished within hours of publication; Lean's own kernel is recorded as taking about half an hour on its export, with under 8 GB. Nothing in this repository has been run on it.
- **The community repository** <https://github.com/leanprover-community/riemann-hypothesis> holds the source, a Comparator setup and a build cache, and is working to make the proof cheaper to build and easier to read. On 2026-11-25 its `main` branch moved to a copy of one edition of the shorter proof above. As read on 2026-11-26, the work done on the original formalization is kept on its branch `alpoge`; the challenge file, export targets and Comparator configuration used in this repository's two later runs are the ones for the original, not those now on `main`. It asks people not to send it claims about their own machine's builds.
- **Other independent checks** include one on the LUMI supercomputer (<https://github.com/aapolipponen/rh-lean-check-lumi>), which also documents the memory-mapping limit and the memory needed by deep modules, and <https://github.com/Hertaspace/alpoge-rh-lean-verification>.
- **The standard these follow** is set out in Kevin Buzzard's post of 2026-11-12, "…and the proof is checked in Lean" (<https://xenaproject.wordpress.com/2026/11/12/and-the-proof-is-checked-in-lean/>), and in the Lean reference, "Validating a Lean Proof" (<https://lean-lang.org/doc/reference/latest/ValidatingProofs/>).

None of this is about whether people understand the mathematics. That is a separate matter, and not one this repository can speak to.

## How the checks here compare

The Lean reference describes an escalating sequence of checks. The pre-registered criteria of this repository reach the third of its four levels. The rows below them were added afterwards, by two further runs that follow the community's method.

| Check | The community's record | This repository |
|---|---|---|
| The whole tree compiles | Yes | Yes (C1) |
| `#print axioms`, and a walk of everything the theorems depend on | Yes | Yes (C2) |
| Kernel replay of every compiled module by `leanchecker` | Yes | Yes (C3) |
| The statements compared with a challenge file that imports only Mathlib (Comparator) | Yes, by several tools | Yes, since 2026-11-26, with two differences from the published run (below): `lake comparator` (Lean v4.36.0), on this repository's export of the community's challenge file and the published copy of the proof's export, which has the SHA-256 of this repository's own, ended with "Your solution is okay!". Before it, `con-leche --compare` (2026-11-24) and `con-ron --compare` each reported all five theorems justified |
| The build made in a sandbox with no network | Yes | No. The cloud run used a dedicated build user on a machine made for the run and deleted after it |
| An export of the proof, checked outside the build | Yes | Yes, since 2026-11-24: the export of the cloud run's compiled files is byte for byte the published one (61,570,595,788 bytes, SHA-256 `5ea74b91…244e`) |
| Lean's own kernel over the whole export | Yes: the default kernel and its paranoid build, each with and without an allocator setting that shortens the run | Yes, since 2026-11-26, with that setting only: the default kernel inside `lake comparator`'s sandbox, and the paranoid build beside it |
| Kernels written independently of Lean's | `nanoda` and `con-leche` on the export; `con-ron`, a port of `con-leche`; `lean4lean` on the compiled modules | Two: `con-leche` accepted all 1,468,418 declarations of the export (2026-11-24) and `nanoda` all 1,484,733 it counts (2026-11-25). `con-ron` gave `con-leche`'s counts. `lean4lean` has not been run |

The rows after the third are the difference between "re-checked by Lean's own kernel" and what the Lean reference calls the gold standard. When this page was first written this repository had none of them. Two runs added something to every one of them but the sandboxed build, each with the limits listed below, using the community's challenge file, targets, exporter, configuration and checkers: the export check of 2026-11-24 ([`../records/cloud/export-check/`](../records/cloud/export-check/)) and the kernel check of 2026-11-25 and 26 ([`../records/cloud/kernel-check/`](../records/cloud/kernel-check/)).

What is still different from the published record:

- **No sandboxed build.** The proof was built here by a dedicated user on a machine made for the run. That the export of that build is byte for byte the published one, which a sandboxed build reproduced, is evidence about it; it is not a sandboxed build.
- **`lake comparator` was not run as published.** Here Lean's kernel was given an allocator setting, passed through the sandbox by a wrapper, and the two external kernels of the community's configuration ran beside `lake comparator`, not inside it. That is what brought the run from 123 hours to 10. The published record has the run without either change.
- **Lean's kernels were run on the export only with the allocator setting.** The published record has each of them without it as well.
- **`lean4lean` has not been run.** Neither has `lake comparator --paranoid`, which the published record of this formalization does not have either: by that record, the further checkers the flag adds do not work on this proof as bundled with Lean v4.36.0.
- **The standalone Comparator (v4.33.0) has not been run.** The published record has it end to end, in 64 hours, as well as `lake comparator`. Nothing here touches that record's second part either, the proof combined with an independent formalization of Robin's criterion.
- The export that the kernel check read is the published copy, which has the SHA-256 of this repository's own export; the 61.6 GB that this repository's export check wrote were not kept.
- Each of these runs was made once. The export check's script has had no reviewer but the AI agent that wrote it; an earlier state of the kernel check's was reviewed by AI agents before it ran. No person has reviewed either.

## Where the results agree

Five things in the record here can be compared with what others published, and each agrees:

- the source archive has SHA-256 `9631b4f0…49c7fc`, as on Sutherland's page;
- the compiled `Main.olean` and `Statements.olean` of the cloud run have SHA-256 `9146dfb4…96ad` and `f8e0aed3…d6b1`, the values Sutherland and the LUMI check give (most other compiled files embed the build directory's path and cannot be compared across machines);
- the export of the challenge file has SHA-256 `bd484ac9…b2b9` and the export of the proof `5ea74b91…244e`, the values on Sutherland's page; this is the strongest of the five, since it covers every declaration the five theorems rest on;
- the walk of everything the five theorems depend on visited 1,478,243 constants, the figure the LUMI check reports and says it shares with a third, independent count.

## What may be useful here

- **Cost.** The published builds used large machines (192 cores, 480 cores, a supercomputer). The run here used one 32-vCPU machine at Spot prices, was interrupted once by the provider and carried on, and is recorded at about 26 USD of machine time at work ([`cloud-notes.md`](cloud-notes.md), section 10.8).
- **The export and an independent kernel on a small machine.** From compiled files already in hand, the export and two runs of `con-leche` took 2.2 hours and 4.49 USD on one 32-vCPU machine; the export is single-threaded and took 95 minutes of that, and `con-leche` under eight minutes a run with a peak of 45 GiB.
- **Comparator and Lean's kernel on the export, in half a day, with the allocator setting of the published record.** `lake comparator` with Lean's kernel in its sandbox, the paranoid kernel, `nanoda` and `con-ron --compare`, on one 32-vCPU machine with 256 GB: 11.5 hours and 22.97 USD. The published record had already run both of Lean's kernels with that setting, in 9 and 10 hours; what is measured here is the same with one of them inside `lake comparator`'s sandbox, on one rented machine, and what it cost. The two long checks use one core each, so the machine was chosen for its memory; `lake comparator` alone peaked at 83 GiB ([`cloud-notes.md`](cloud-notes.md), section 10.10).
- **A laptop.** A build on a 24 GB Mac is in progress, with what it took to keep it within memory written down ([`performance-notes.md`](performance-notes.md)). No finished laptop build had been found in what was read on 2026-11-23.
- **The replay.** Run once per module with the whole library on its search path, `leanchecker` slows as the tree grows; given only each module's imports it replayed the tree in 7.2 hours on 32 vCPUs ([`performance-notes.md`](performance-notes.md), section 10).
- **Scripts that need no AI tool and little Lean.** Each step is a shell script that says what it does and what it changes.

Whether any of this is new to the people who did the work above is not known: the main discussion, on the Lean Zulip, had not been read when this was written.

The shorter proof changes what most people will want to run, and the community repository has already moved to it. By the figures on its page, read on 2026-11-26, a full check of its compact edition, `lake comparator --paranoid` included, took about three hours on one 16-core machine with 128 GB. For its readable edition the same run on that machine was stopped without a verdict, because `lean4lean` needs 332 GB there; it passed on a 192-core machine with 1.5 TB, in a little over four hours. Its README gives one to two hours for a build on 12 cores with 24 GB. Neither edition needs a method for very large archives. What is recorded here concerns the original formalization, and archives of its size.

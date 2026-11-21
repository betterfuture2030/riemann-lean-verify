# Cloud price and capacity records

The research behind the choice of machine for the Google Cloud pilot in [`../../cloud/gcp/`](../../cloud/gcp/), and, in [`pilot/`](pilot/), what the pilot then measured.

## Date and source

All prices were read on **2026-11-20**.

The Google Compute Engine rates come from **Google's public SKU catalogue** (`cloud.google.com/skus`, every entry with an effective date of 2026-11-20) and were cross-checked against the hourly tables on Google's public pricing pages. They are for `us-central1` (Iowa), in US dollars, for Linux, on demand and Spot, with no committed-use discount and before tax. `gcp_pricing.json` gives a source URL and the arithmetic for each machine price.

Prices for other providers in `cloud_options.json` were read on the same date. Each entry names its source, and a few are marked as coming from a third-party site or from memory.

This is a dated snapshot, not a quotation. Cloud prices, Spot prices in particular, change without notice. Read the current prices before spending anything.

## What kind of evidence this is

`cloud_options.json`, `gcp_pricing.json` and `gcp_budget_review.json` were written by AI research agents with web access. Parts of the first two were re-checked by further agents, whose results are stored alongside (`checks`, `skeptic`). `gcp_budget.json` is the output of a short budget script, and `gcp_budget_review.json` is three agents' criticism of it. `gcp_family_rates.json`, `gcp_candidates.json` and `gcp_machine_types.csv` are extracts of Google's catalogue data.

- A price marked `first_party: true` was read from the provider's own page or catalogue. Statements the agents marked "from memory" or "not re-checked" are exactly that.
- Every time and cost estimate is a model. The only measured input is the local compile rate in [`../mac-build/tuning2.tsv`](../mac-build/tuning2.tsv). The conversion from that rate to hours on a rented machine rests on assumed factors, and the reviews in these files dispute several of them.
- The files in this directory were written before anything had run in the cloud, and none of their estimates had been compared with a real run. The pilot ran later on 2026-11-20. Its measurements and the estimate derived from them are in [`pilot/`](pilot/); they supersede the time and cost models here, which are kept as a record of what was believed beforehand and how far off it was.

## Files

| File | Contents |
|---|---|
| `cloud_options.json` | `research`: four notes (`aws`, `gcp-azure`, `budget-baremetal`, `lean-scaling`), each with options, practicalities and caveats. `synthesis`: ranked recommendations, a time model, set-up steps and the main uncertainties. `checks`: independent re-reads of five of the quoted prices. `skeptic`: a critical review of the time model, with a revised range of 3.5 to 40 hours |
| `gcp_pricing.json` | `amd` and `intel`: per-family component rates and whole-machine hourly prices, on demand and Spot, with the arithmetic. `storage`: disk options and prices, billing rules, and what budget alerts do and do not do. `quota`: how Compute Engine quotas apply to large machines and which increases each machine would need. `checks`: independent re-reads of 22 prices |
| `gcp_family_rates.json` | Component rates by machine family, extracted from the SKU catalogue for `us-central1`. A key is `FAMILY|Core|OnDemand`, `FAMILY|Ram|OnDemand`, or the same with `Preemptible`, which is the catalogue's name for Spot. `Core` values are US dollars per vCPU-hour; `Ram` values are US dollars per GiB-hour |
| `gcp_budget.json` | Output of a budget model. `inputs`: the local rate (3,230.4 modules per hour at a cap of 8), the assumed scenario factors, and the resulting amount of work in performance-core-hours. `options`: six machine configurations, A to F, each with `low`, `expected` and `high` scenarios giving build, verification and billed hours and compute, disk and total cost |
| `gcp_budget_review.json` | Three reviews of `gcp_budget.json`, by `lens`: `model-skeptic`, `gcp-operations` and `alternatives`. Each has `overall`, `summary`, `errors`, `revised_option_A` and `recommendation`. All three rate the model `usable_with_corrections` |
| `gcp_candidates.json` | 31 machine types with at least 96 vCPUs that were considered: vCPUs, memory in GB, the US regions that offer them, and the `us-central1` zones that do |
| `full_run_driver_review.json` | Four AI reviews of the first draft of the full-run driver, made before it had been run. Criticism of code, not a result |
| `full_run_driver_recheck.json` | Two AI reviews of the driver as rewritten after the first four, also before it had been run |
| `full-rehearsals/` | Records of each rehearsal of the full-run driver; see its README |
| `gcp_machine_types.csv` | 1,877 rows, no header: machine type, zone, vCPUs, memory in GB. It lists the 168 machine types with at least 96 vCPUs across 19 zones in `us-central1`, `us-east1`, `us-east4`, `us-east5`, `us-south1` and `us-west1`, as offered on 2026-11-20 |

Where the reviews mention current quota values, such as a limit of 32 vCPUs across all regions, they describe the Google Cloud project that was used for this work on that date. Your project's limits will differ; check them in the console.

## Sanitising

`gcp_pricing.json` and `gcp_budget_review.json` each named a temporary directory on the machine where the research was run. Those paths now read `<SCRATCH>`. The other files are byte-for-byte copies. See [`../README.md`](../README.md).

## Not included

- The raw SKU catalogue (about 29 MB, 33,659 entries). It is public; download the current one from Google.
- Quota responses and the pilot's local state file. They describe one cloud account. The pilot's spend ledger, which names no account, is in [`pilot/ledger.tsv`](pilot/ledger.tsv).

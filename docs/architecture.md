# Architecture decisions

Lightweight ADRs: context → decision → consequences / alternatives considered.

## ADR-1 Cache the dataset locally instead of proxying data.gov.sg

**Context.** The UI needs interactive filtering, sorting, aggregation (averages by
month/town, segment comparisons) and sub-second responses. Measured upstream latency is
3–6 s per 1,000-row page; anonymous traffic is rate limited; the datastore API offers only
equality filters, offset paging and simple sort.

**Decision.** A background timer copies the dataset into OutSystems entities, and every user
request is served from local indexed tables.

**Consequences.** Fast, rich queries; resilient to upstream outages (stale but available,
surfaced by `/health`). Data is up to `Sync_RefreshIntervalHours` old, which is fine for a
dataset published monthly. Costs about 245 upstream calls per refresh.

*Rejected:* live proxy with a short cache (still slow for aggregates and fragile under rate
limits); client-side fetching of the whole dataset (≈50 MB JSON per visit).

## ADR-2 Full snapshot loads into staging, published by an atomic swap

**Context.** I observed that upstream `_id`s are not stable: recent months appear at the
tail with re-assigned ids after republication. There is no natural unique key (several
identical flats can sell in the same block, month and storey range).

**Decision.** Each refresh loads the whole dataset into `ResaleTransactionStaging`. When
complete, `Sync_PublishSnapshot` runs `DELETE` + `INSERT … SELECT` in a single transaction.

**Consequences.** Always correct, including upstream revisions and deletions. Readers never
see a half-loaded table. Doubles storage during a load (~2×60 MB, negligible).
*Rejected:* upsert by `_id` (wrong under re-ordering); upsert by a composite natural key
(not unique); table rename / partition switch (faster, but outside what the platform manages
and a risk to platform-managed metadata).

## ADR-3 Resumable, chunked processing with per-page commit

**Context.** A full load is about 245 pages × (≈5 s fetch + ≈1.5 s insert) ≈ 25 minutes,
longer than a sensible single timer execution. Network or upstream errors are expected.

**Decision.** `SyncRun` doubles as a checkpoint (`NextOffset`, `RemoteTotal`,
`LastHeartbeatOn`). `Sync_ProcessPages` commits after every page, together with the
advanced checkpoint. The timer processes `Sync_MaxPagesPerRun` pages, then wakes itself. Any
error leaves the run Running with the error recorded, and the next execution resumes. A
changed remote total raises `DatasetChangedException`, which fails the run and restarts it
immediately. Runs without a heartbeat for `Sync_StaleRunMinutes` are abandoned.

**Consequences.** Bounded work per execution, at most one page lost on failure,
self-healing, and a full audit trail visible in the Data Sync screen.

## ADR-4 Validate and normalise at the boundary (`MapResaleRecord`)

All upstream values arrive as JSON strings. A pure server action converts and validates
them (month format, positive numeric price and area, mandatory town and flat type),
normalises case, and caps lengths to the column sizes. It also derives `StoreyMin`,
`PricePerSqm` and `RemainingLeaseMonths`. The lease field has three historical formats
(`"61 years 04 months"`, `"61 years"`, `"70"`) and is sometimes missing; the missing case is
derived from the 99-year lease start. Invalid rows are counted (`RecordsRejected`) rather
than failing the load. Because these functions are pure, they are the unit-test targets.

## ADR-5 Aggregates for screens, parameterised SQL for the API

Screens use aggregates: the platform optimises the selected columns, handles paging, sorting
and counts, and they stay easy to maintain. The public API needs a median and an
allow-listed sort, so it uses SQL nodes with parameters only (no `Expand Inline`). The sort
is applied through `CASE WHEN @SortBy = '…'`, so user input can never change the statement.

## ADR-6 Testing where the logic lives

OutSystems logic can't be imported into an external test runner, so unit tests run *inside*
the platform (`SelfTest_RunAll`, table-driven: arrange → act → assert, 20 cases) and are
triggered and asserted from CI through `SelfTestAPI`. External suites cover the API contract,
the UI (Playwright) and upstream drift. IaC is tested offline with `terraform test` and a
mocked provider. In a multi-module factory the self-tests would move to a dedicated test
module that is never deployed to Production.

## ADR-7 One environment per Terraform state; servers are cattle-ish

Each OutSystems environment (LifeTime, Dev, Test, Prod) has its own VPC, database and state
file, so a mistake in Dev can't touch Prod and environments can be rebuilt independently.
Front-ends are plain EC2 instances, not an Auto Scaling group. OutSystems front-ends must be
registered with the Deployment Controller, and scale-in needs deregistration, so a fixed,
explicitly managed count is safer. EC2 auto-recover and AWS Backup provide the self-healing.
Patching runs one server at a time.

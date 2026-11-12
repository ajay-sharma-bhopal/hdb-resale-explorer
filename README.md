# HDB Resale Explorer — OutSystems + data.gov.sg

A full-stack OutSystems 11 (Reactive Web) application that lets citizens and policy
officers explore **every HDB resale flat transaction registered since January 2017**
(~244,000 rows), sourced from data.gov.sg. This repository contains everything that is
not inside the OutSystems module itself: the **AWS Infrastructure as Code** for running
the OutSystems Platform, the **automated tests**, the **CI/CD pipelines** and this
documentation.

| Deliverable | Where |
|---|---|
| OutSystems application (module `Assessment`) | OutSystems environment (access provided separately) |
| AWS IaC for the OutSystems Platform | [`infra/terraform`](infra/terraform) |
| Automated tests | [`tests`](tests) + in-platform `SelfTest_RunAll` + [`infra/terraform/tests`](infra/terraform/tests) |
| CI/CD | [`.github/workflows`](.github/workflows), [`scripts/lifetime_deploy.py`](scripts/lifetime_deploy.py) |
| Design decisions | [`docs/architecture.md`](docs/architecture.md) |

---

## 1. What the application does

**Dataset:** [Resale flat prices based on registration date from Jan-2017 onwards](https://data.gov.sg/datasets/d_8b84c4ee58e3cfc0ece0d773c8ca6abc/view)
(Housing & Development Board, resource `d_8b84c4ee58e3cfc0ece0d773c8ca6abc`). I chose it
because it is large, refreshed monthly and relevant to MSF's family-services work, and it
supports more than a table: you can segment it, rank it, trend it over time and compare a
single sale with the market.

| Screen | Access | Capabilities |
|---|---|---|
| **Overview** (`Dashboard`, default) | Public | Segment by town, flat type and period. Shows KPI counters (transactions, average price, average price per sqm, highest price), a monthly price trend (line chart), the flat-type mix (donut chart) and a ranking of average price by town (bar chart). Deep-links into the explorer with the same filters. Shows data freshness. |
| **Explore** (`Transactions`) | Public | Search by street or block; filter by town, flat type, price range and date range; server-side sort on any column; pagination; empty and loading states. |
| **Transaction details** | Public | Full record. Compared with its 12-month segment (same town and flat type): segment average, % above/below average, average price per sqm and highest price. Lists other sales in the same block. |
| **Data Sync** | `DataAdmin` role | Load history with status tags and progress, snapshot size, and a "Refresh data now" button (role-checked on the server). |
| **REST API** `/rest/ResaleAPI` | Public, read-only | `GET /transactions`, `GET /summary` (includes the median), `GET /health`. |

## 2. Architecture

```mermaid
flowchart LR
  subgraph data.gov.sg
    DS[(datastore_search<br/>HDB resale prices)]
  end
  subgraph OutSystems module "Assessment"
    direction TB
    RC[REST consumer<br/>DataGovSG.DatastoreSearch] --> PP
    T((Timer<br/>SyncResaleTransactions<br/>hourly + self-wake)) --> RR[Sync_ResolveRun] --> PP[Sync_ProcessPages<br/>page → MapResaleRecord → staging<br/>commit + checkpoint per page]
    PP --> STG[(ResaleTransactionStaging)]
    PP -->|load complete| PUB[Sync_PublishSnapshot<br/>atomic SQL swap]
    STG --> PUB --> TX[(ResaleTransaction<br/>indexed snapshot)]
    RUN[(SyncRun<br/>checkpoint + audit)] --- PP
    TX --> AGG[Screen aggregates] --> UI[Reactive UI<br/>Overview · Explore · Details · Data Sync]
    TX --> SQL[Resale_Search / Resale_GetSummary<br/>parameterised SQL] --> API[ResaleAPI REST]
    ST[SelfTest_RunAll] --> STAPI[SelfTestAPI REST]
  end
  DS <-- HTTPS JSON --> RC
  CI[GitHub Actions] -->|pytest / Playwright| API & STAPI & UI
```

**The key design decision is to sync and cache the data, not proxy it.** The UI never calls
data.gov.sg at request time. A timer copies the dataset into the OutSystems database, and
every screen queries local, indexed tables. Why:

* **Rate limits and latency.** data.gov.sg rate-limits anonymous traffic and takes 3–6 s
  per 1,000-row page. Live proxying would make every filter change slow and would fail
  under load.
* **Interactive analytics.** Aggregations (averages by town or month, the median,
  comparisons with the segment) need the whole dataset. The datastore API offers only
  simple filters and offsets.
* **Availability.** If data.gov.sg is down, the app keeps serving the last good snapshot,
  and `/health` reports it as `STALE`.

**The sync is resumable and consistent.** Upstream `_id`s are *not stable*: data.gov.sg
republishes the dataset, and I saw recent months re-ordered at the tail. Incremental sync
by `_id` would therefore create duplicates or miss rows. Instead, each load is a
**full snapshot**:

1. `Sync_StartRun` records the remote row count, clears the staging table and creates a
   `SyncRun` at offset 0.
2. `Sync_ProcessPages` fetches pages of `Site.Sync_PageSize` rows (sorted by `_id`),
   validates and maps every row (`MapResaleRecord`) into staging, and **commits after
   every page together with the advanced checkpoint**. A crash, timeout or API error
   loses at most one page, and the next run resumes from the checkpoint.
3. If the remote total changes mid-load, `DatasetChangedException` fails the run and a
   fresh one starts straight away.
4. `Sync_PublishSnapshot` swaps staging into `ResaleTransaction` with `DELETE` +
   `INSERT…SELECT` **in one transaction**, so readers see either the old or the new
   snapshot, never a mix.
5. The timer processes `Site.Sync_MaxPagesPerRun` pages per execution (well within its
   timeout) and wakes itself until the load is finished. A load with no heartbeat for
   `Site.Sync_StaleRunMinutes` is marked Abandoned and replaced.

More detail, alternatives and trade-offs are in [`docs/architecture.md`](docs/architecture.md).

### Module structure (inside OutSystems)

| Layer | Elements |
|---|---|
| Integration | REST consumer `DataGovSG` (`DatastoreSearch`), DTOs `ResaleRecordDTO`, `DatastoreResultDTO`, `DatastoreSearchResponseDTO`; optional `x-api-key` header (`Site.DataGovSG_ApiKey`, secret, not sent when empty) |
| Data | `ResaleTransaction` (indexes on month; town + flat type + month; street + block), `ResaleTransactionStaging`, `SyncRun`, static `SyncStatus` |
| Domain logic (pure, unit-tested) | `ParseMonthText`, `ParseRemainingLeaseMonths`, `MapResaleRecord` |
| Sync orchestration | `Sync_ResolveRun`, `Sync_StartRun`, `Sync_ProcessPages`, `Sync_PublishSnapshot`, `Sync_UpdateRunStatus`, timer `SyncResaleTransactions` → `Timer_SyncResaleTransactions`, `Admin_RequestRefresh` |
| Query services | `Resale_Search`, `Resale_GetSummary` |
| Exposed APIs | `ResaleAPI` (`/transactions`, `/summary`, `/health`), `SelfTestAPI` (`/run`) |
| UI | `MainFlow`: `Dashboard`, `Transactions`, `TransactionDetail`, `DataSync`; theme CSS uses the OutSystems UI design tokens |
| Configuration (Site Properties) | `DataGovSG_ResourceId`, `DataGovSG_ApiKey`, `Sync_Enabled`, `Sync_PageSize`, `Sync_MaxPagesPerRun`, `Sync_RefreshIntervalHours`, `Sync_StaleRunMinutes`, `SelfTests_Enabled` |
| Security | Role `DataAdmin` (screen gate **and** server-side `CheckDataAdminRole()`); public screens use the Anonymous role |

## 3. Infrastructure as Code (AWS)

[`infra/terraform`](infra/terraform) defines the AWS infrastructure for a **self-managed
OutSystems 11 platform**. There is one state file per environment: `lifetime`, `dev`,
`test` and `prod`.

```mermaid
flowchart TB
  U[Users] --> WAF[AWS WAF<br/>managed rules + rate limit] --> ALB[ALB · TLS 1.3/1.2<br/>HTTP→HTTPS]
  subgraph VPC per environment
    subgraph public subnets
      ALB
      NAT[NAT GW per AZ in prod]
    end
    subgraph app subnets
      DC[Deployment Controller<br/>Windows + IIS + RabbitMQ]
      FE1[Front-end 1] & FE2[Front-end N]
    end
    subgraph data subnets - no internet route
      RDS[(RDS SQL Server<br/>Multi-AZ in prod · KMS · TLS forced)]
    end
    VPCE[VPC endpoints<br/>SSM · Logs · Secrets · KMS · S3]
  end
  ALB -->|HTTPS 443| FE1 & FE2
  DC <-->|12000-12004, 5672| FE1 & FE2
  FE1 & FE2 & DC -->|1433| RDS
  FE1 & FE2 & DC --> NAT --> DG[data.gov.sg / OutSystems services]
```

| Module | Highlights |
|---|---|
| `network` | 3-tier VPC (public / app / data) across 2–3 AZs; data tier has no internet route; NAT per AZ in prod; VPC endpoints so SSM and logging work without the internet; VPC flow logs (KMS); default SG locked down |
| `edge` | ALB with `ELBSecurityPolicy-TLS13-1-2-2021-06`, HTTP→HTTPS 301, re-encryption to targets, `drop_invalid_header_fields`; WAFv2 (Common, KnownBadInputs, SQLi, IP reputation, per-IP rate limit; body-size rule set to *count* for Service Center/LifeTime uploads); access-log bucket (TLS-only policy, lifecycle); optional Route 53 alias |
| `outsystems_servers` | Deployment Controller + N front-ends (Windows Server 2022 from the AWS SSM public AMI parameter); IMDSv2 only; encrypted gp3; **no RDP / key pairs** (SSM Session Manager); least-privilege role (installer bucket, DB secret, KMS); bootstrap installs IIS prerequisites and the CloudWatch agent, then installs and configures the Platform Server. DB credentials are read from Secrets Manager at boot and never stored in user data or state |
| `database` | RDS SQL Server (SE/EE, Express for dev only, enforced by a precondition); KMS encryption; `rds.force_ssl`; RDS-managed master password in Secrets Manager; Multi-AZ, PITR backups, deletion protection and a final snapshot; Performance Insights; enhanced monitoring; error/agent logs to CloudWatch |
| `operations` | SNS alarms (KMS) for ALB 5xx, unhealthy targets, latency, RDS CPU/storage, and EC2 status checks with **auto-recover**; AWS Backup (daily, tag-based); SSM patch baseline plus a maintenance window that patches **one server at a time** to keep the ALB healthy |

Usage:

```bash
cd infra/terraform
terraform init -backend-config=envs/prod.backend.hcl
terraform plan  -var-file=envs/prod.tfvars -out prod.tfplan
terraform apply prod.tfplan
```

Prerequisites outside this stack: an ACM certificate, the Terraform state bucket and lock
table, and a private installer bucket holding `outsystems/<version>/PlatformServer-<version>.exe`
plus `configure-platform.ps1`. Keeping that script with the installer pins the
version-specific Configuration Tool arguments to the platform version.

> **GCC note.** On GCC 2.0 the landing zone already provides the VPC, egress and some
> security controls. The `network` module is then replaced by the agency's existing
> VPC/subnet IDs; the other modules are unchanged.

## 4. Testing strategy

| Level | What | How it runs |
|---|---|---|
| **Unit (in-platform)** | 20 cases covering `ParseMonthText`, `ParseRemainingLeaseMonths` (all upstream lease formats and edge cases) and `MapResaleRecord` (normalisation, price per sqm, each rejection rule). The logic lives in OutSystems, so the tests execute there via `SelfTest_RunAll`. | `GET /rest/SelfTestAPI/run`, asserted by [`tests/api/test_selftests.py`](tests/api/test_selftests.py) |
| **API / integration** | Response shape, filters (case-insensitive), every sort option, SQL-injection-safe sort, paging without overlap, `maxRecords` clamp, date validation (400), summary consistent with search, median within [min, max], snapshot health | [`tests/api/test_resale_api.py`](tests/api/test_resale_api.py) (pytest) |
| **Upstream contract** | Detects schema or format drift in data.gov.sg *before* it breaks the sync: field set, row-count plausibility, month/lease/storey formats, numeric prices, deterministic `_id` paging | [`tests/contract`](tests/contract), nightly |
| **End-to-end UI** | Dashboard KPIs and charts render; a filter changes the KPIs; explore → filter → sort → detail; pagination; admin screen requires login | [`tests/e2e`](tests/e2e) (Playwright) |
| **IaC** | `fmt`, `validate`, `tflint`, `checkov`, plus `terraform test` with a **mocked AWS provider** asserting invariants: prod is Multi-AZ, encrypted, private and deletion-protected; front-ends (not the controller) serve prod traffic; NAT per AZ; IMDSv2; TLS policy and redirect; WAF on; Express cannot be Multi-AZ; bad inputs rejected | [`infra/terraform/tests`](infra/terraform/tests), every PR |

```bash
pip install -r tests/requirements.txt
pytest tests/contract                       # needs only internet access
export APP_BASE_URL=https://<env>/Assessment
pytest tests/api                            # in-platform unit tests + API tests
python -m playwright install chromium && pytest tests/e2e -m e2e --browser chromium
cd infra/terraform && terraform init -backend=false && terraform test
```

**CI/CD.** [`ci.yml`](.github/workflows/ci.yml) runs the IaC checks and upstream contract
tests on every PR, and nightly runs the full regression against Dev.
[`deploy.yml`](.github/workflows/deploy.yml) uses the **LifeTime Deployment API v2**:
it tags a version in Development, deploys it to Test, runs the regression suite, and only
then promotes **that exact version** to Production behind a protected-environment approval,
followed by a read-only smoke test.

## 5. Security and compliance notes

* Public data, so the screens and API are anonymous and read-only. The only write path
  (`Admin_RequestRefresh`) is gated by the `DataAdmin` role on the screen **and** on the
  server.
* SQL uses parameters only. The sort column is allow-listed inside a `CASE`; there is no
  `Expand Inline`.
* The upstream response is untrusted: every field is validated and length-capped, and bad
  rows are counted and skipped rather than failing the load.
* API keys are secret Site Properties set per environment, marked *sensitive* so they are
  masked in integration logs.
* Infrastructure: encryption at rest (KMS) and in transit (TLS to ALB, ALB → IIS, app →
  SQL), no public IPs on servers, no SSH/RDP, IMDSv2, WAF, flow logs, audit-friendly
  `SyncRun` history.
* `SelfTests_Enabled` should be **False** in Production. The self-tests have no side
  effects, but the endpoint has no purpose there.

## 6. Assumptions, trade-offs and next steps

* **Single module, layered internally.** The assessment environment provided one module, so
  layers are separated by naming and responsibility rather than by module. In a real
  factory I would split it (Architecture Canvas): `DataGovSG_IS` (integration),
  `HDBResale_CS` (entities, sync, query services), `HDBResale_API`, `HDBResale` (UI), and a
  `HDBResale_Tests` module. Then `SelfTestAPI` would not ship to Production at all.
* **Full refresh vs incremental.** A full snapshot takes about 245 API calls a day, which
  is trivial for upstream. In exchange it is always correct, even when upstream re-orders
  or revises rows. If the dataset grew 100×, I would switch to month-partitioned refreshes
  (re-load only the trailing N months).
* **Row-by-row inserts** into staging (about 1–2 s per 1,000 rows) are simple and
  transactional per page. A bulk-insert extension could make loads about 10× faster if
  needed.
* **Median** is only exposed through the API, because aggregates can't compute it
  (`PERCENTILE_CONT` needs SQL). Screens use aggregates for platform-optimised,
  automatically paged queries.
* The text search uses `LIKE '%term%'`, which can't use an index. At 244k rows it stays
  sub-second; a full-text index is the next step at larger scale.
* `configure-platform.ps1` (the unattended Configuration Tool call) is intentionally kept
  next to the installer rather than in this repo, because its arguments are
  platform-version specific.
* AI extension (the JD asks for AI integration): a natural next step is a "Describe the
  market" summary or a natural-language query over `Resale_GetSummary`, using
  OutSystems' AI connectors, with the LLM given only aggregated, public numbers.

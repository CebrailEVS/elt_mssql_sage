# elt_mssql_sage

ELT pipeline extracting data from a **Microsoft SQL Server (Sage ERP)** database and loading it into **BigQuery**. Built with [Meltano](https://meltano.com/) and deployed as a **Google Cloud Run Job**.

---

## What it does

1. Extracts tables from a MSSQL/Sage database via `tap-mssql`
2. Loads them into BigQuery (raw layer) via `target-bigquery`
3. A **Cloud Workflow** orchestrates the full pipeline daily: EL → dbt transform

A single `tap-mssql → target-bigquery` run extracts all Sage tables. Replication is mixed per table:

| Table | Type | Replication | Loader behavior |
|---|---|---|---|
| `F_ECRITUREC` | fact (large) | INCREMENTAL on `cbModification` | append |
| `F_ECRITUREA` | fact (large) | INCREMENTAL on `cbModification` | append |
| `F_DOCLIGNE` | fact (large) | INCREMENTAL on `cbModification` | append |
| `F_COMPTET` | dimension | FULL_TABLE | overwrite |
| `F_COLLABORATEUR` | dimension | FULL_TABLE | overwrite |

Fact tables replicate only rows whose `cbModification` changed and **append** to BigQuery; dbt dedups by `cbMarq` / `max(cbModification)` downstream. Small dimensions are full-refreshed (also captures hard-deletes). Primary key on every table is `cbMarq`; the high-water mark is stored in a GCS state backend (see below).

Some Sage columns contain spaces (e.g. `ANCIEN CODE ARTICLE`), which BigQuery rejects. They are renamed to snake_case via inline **stream maps** in the tap config — this replaces the old JSON-loader workaround, so all columns now load natively typed.

---

## Project structure

```
elt_mssql_sage/
├── meltano.yml          # All pipeline config: plugins, environments
├── Dockerfile           # Builds the Cloud Run image
├── plugins/             # Meltano plugin lock files (auto-generated)
├── .github/
│   └── workflows/
│       └── deploy.yml   # CI/CD: build & push on every push to master
└── .gitignore
```

---

## meltano.yml explained

### Extractors

**`tap-mssql`** — connects to the Sage MSSQL database and extracts all selected tables (accounting + commerce/CRM).
- Uses the `buzzcutnorman` variant (better Python 3.11 / pymssql compatibility)
- All connection details come from environment variables (`TAP_MSSQL_*`)
- Schema is fixed to `dbo`
- `metadata` sets `replication-method` per table (INCREMENTAL on `cbModification` for facts, FULL_TABLE for dimensions) and `key-properties: [cbMarq]`
- `stream_maps` rename columns containing spaces (e.g. `ANCIEN CODE ARTICLE` → `ancien_code_article`) so they load as valid BigQuery columns

### Loaders

**`target-bigquery`** — loads data using BigQuery's Storage Write API (fast, streaming).
- `denormalized: true` → each Singer field becomes a BigQuery column
- `overwrite` is a list matching only the dimension streams (`*F_COMPTET*`, `*F_COLLABORATEUR*`) → those are truncated each run; fact tables append (incremental)
- Column name transforms applied automatically (snake_case, lowercase, etc.)

### Environments

| Environment | Dataset used |
|---|---|
| `dev` | `$TARGET_BIGQUERY_DATASET_RAW_DEV` |
| `prod` | `$TARGET_BIGQUERY_DATASET_RAW_PROD` |

The environment is passed at runtime: `meltano --environment=prod run tap-mssql target-bigquery`

### Incremental state

Incremental bookmarks (the max `cbModification` seen per stream) are stored in a **GCS state backend**, set via `MELTANO_STATE_BACKEND_URI` (one prefix per pipeline, e.g. `gs://evs-datastack-meltano-state/mssql-sage`). This is injected as an env var on the Cloud Run Job by Terraform — not committed here. State is keyed by `state_id` (`{env}:tap-mssql-to-target-bigquery`), so dev and prod keep independent bookmarks. The runtime SA reads/writes the bucket via the mounted `gcp-key.json`. State persists only on a successful run, so a failed run safely retries from the last good bookmark.

---

## Environment variables

These must be set at runtime (injected via Secret Manager on Cloud Run):

| Variable | Description |
|---|---|
| `TAP_MSSQL_HOST` | MSSQL server hostname |
| `TAP_MSSQL_PORT` | MSSQL port (usually 1433) |
| `TAP_MSSQL_USER` | DB username |
| `TAP_MSSQL_PASSWORD` | DB password |
| `TAP_MSSQL_DATABASE` | Database name |
| `TARGET_BIGQUERY_PROJECT` | GCP project ID |
| `TARGET_BIGQUERY_LOCATION` | BigQuery location (e.g. `europe-west1`) |
| `TARGET_BIGQUERY_CREDENTIALS_PATH` | Path to the GCP service account JSON key |
| `TARGET_BIGQUERY_DATASET_RAW` | Target dataset (overridden per environment) |
| `TARGET_BIGQUERY_DATASET_RAW_DEV` | Raw dataset for dev |
| `TARGET_BIGQUERY_DATASET_RAW_PROD` | Raw dataset for prod |
| `MELTANO_STATE_BACKEND_URI` | GCS path for incremental state, e.g. `gs://evs-datastack-meltano-state/mssql-sage` (required for incremental replication) |

---

## Dockerfile

The image is based on `meltano/meltano:latest-python3.11` (full image, not slim).

**Why the full image?** `tap-mssql` uses `pymssql` which requires MSSQL system drivers. The slim Meltano image excludes them.

**Why Python 3.11?** `pymssql` ships binary wheels for 3.11 — no compilation needed, faster and more reliable builds.

All plugins are installed at **build time** (`meltano install`), so the container starts instantly with no setup at runtime. The project is set to read-only (`MELTANO_PROJECT_READONLY=1`) to prevent accidental state changes inside the container.

---

## Deployment

### Infrastructure

The Cloud Run Job is defined in the infra Terraform repo (`cloudrun.tf`):
- Job name: `elt-mssql-sage`
- Region: `europe-west1`
- Runtime service account: `meltano-runner@evs-datastack-prod.iam.gserviceaccount.com`
- Secrets injected via Secret Manager at `/secrets/`

### Orchestration

The full pipeline (EL + dbt) is orchestrated by **Google Cloud Workflows** (`pipeline-mssql-sage.yaml`), triggered daily by Cloud Scheduler:

```
Cloud Scheduler → Cloud Workflow
                      ├── Cloud Run Job: tap-mssql → target-bigquery (all tables)
                      └── Cloud Run Job: dbt-runner (tag:mssql_sage)
```

### CI/CD

Every push to `master` triggers the GitHub Actions workflow (`.github/workflows/deploy.yml`):

1. Authenticates to GCP using a service account key (`GCP_SA_KEY` secret)
2. Builds the Docker image
3. Pushes it to Artifact Registry as `elt-mssql-sage:latest`
4. Updates the Cloud Run Job to use the new image

The next Cloud Workflow execution will automatically pick up the updated image.

---

## Running locally

```bash
# Install plugins
meltano install

# Run extraction (dev environment) — all tables in one run
meltano --environment=dev run tap-mssql target-bigquery
```

Requires a local `.env` file with the variables listed above.

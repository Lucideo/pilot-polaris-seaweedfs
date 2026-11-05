# Pilot: Apache Polaris + SeaweedFS lakehouse

A small, local-only pilot I built to learn **[Apache Polaris](https://polaris.apache.org/)** and **[SeaweedFS](https://seaweedfs.com)**, an Apache Iceberg REST catalog. It runs a self-hosted lakehouse on Docker:

- **SeaweedFS** provides S3-compatible object storage.
- **Polaris** is the Iceberg catalog, backed by **PostgreSQL**.
- **DuckDB** ingests data and queries the Iceberg tables through the catalog.

The dataset is the [USGS earthquake feed](https://earthquake.usgs.gov/earthquakes/feed/v1.0/csv.php) for the past week. It moves through a simple bronze → silver flow.

> This is a learning project. Credentials in `s3.json` and `.env` are placeholders, and none of the setup is hardened for production.

## Architecture

```
                 USGS CSV feed (https)
                          │
                          ▼
              ┌───────────────────────┐
              │  DuckDB (Python)      │
              │  bronze_ingestion.py  │──── writes parquet ────┐
              │  silver_load.py       │                        │
              │  analysis.py          │                        ▼
              └──────────┬────────────┘        ┌──────────────────────────────┐
                         │ Iceberg REST        │  SeaweedFS (S3 API :8333)    │
                         │ + OAuth2            │  bucket: lakehouse           │
                         ▼                     │   ├── bronze/raw_data.parquet│
              ┌───────────────────────┐        │   └── usgs/… (Iceberg data   │
              │  Apache Polaris       │───────▶│            + metadata)      │
              │  :8181 API, :8182 mgmt│        └──────────────────────────────┘
              └──────────┬────────────┘           master · volume · filer · s3
                         │ JDBC
                         ▼
              ┌───────────────────────┐
              │  PostgreSQL 17        │
              │  (Polaris metastore)  │
              └───────────────────────┘
```

| Service             | Container         | Port(s)      | Role                                          |
| ------------------- | ----------------- | ------------ | --------------------------------------------- |
| `master`            | `sw-master`       | 9333         | SeaweedFS master                              |
| `volume`            | `sw-volume`       | 8080         | SeaweedFS volume server                       |
| `filer`             | `sw-filer`        | 8888         | SeaweedFS filer                               |
| `s3`                | `sw-s3`           | 8333         | S3 gateway; identities come from `s3.json`    |
| `polaris-db`        | `polaris-db`      | (internal)   | PostgreSQL persistence for Polaris            |
| `polaris-bootstrap` | (one-off)         | n/a          | Bootstraps the realm and root credentials     |
| `polaris`           | `polaris`         | 8181, 8182   | Iceberg REST catalog (8181) and health (8182) |

All services share the Docker network `polaris-seaweed-pilot`.

## Repository layout

```
.
├── compose.yml              # SeaweedFS + Postgres + Polaris stack
├── s3.json                  # SeaweedFS S3 identities (admin, reader, polaris, duckdb)
├── catalog.json             # Polaris catalog definition ("usgs" → s3://lakehouse/usgs)
├── Makefile                 # Every step of the pilot as a make target
├── requirements.txt         # Python deps (duckdb)
├── .env                     # Local config and secrets (not committed)
└── scripts/
    ├── bronze_ingestion.py  # USGS CSV → s3://lakehouse/bronze/raw_data.parquet
    ├── silver_load.py       # bronze parquet → Iceberg table usgs.silver.earthquakes
    ├── analysis.py          # queries the Iceberg table through Polaris
    └── pyiceberg_catalog.py # earlier experiment: PyIceberg + local SQLite catalog (no Polaris)
```

## Prerequisites

- Docker with Compose v2
- `make`, `curl`, `jq`
- Python 3.10+

## Configuration

The Makefile and the Python scripts read their settings from `.env`. Create it with these variables. The values shown are examples; the S3 keys must match the identities in `s3.json`.

> The Makefile currently requests its admin token with the literal credentials `root` / `s3cr3t`. Keep `POLARIS_ROOT` and `POLARIS_ROOT_SECRET` set to those values, or change the `TOKEN` line in the Makefile.

## Running the pilot

### 1. Start Postgres and bootstrap Polaris

The bootstrap creates the realm and the root principal in the metastore. Run it once, before Polaris first starts.

```bash
make p_postgres_up
make p_bootstrap
```

### 2. Start the rest of the stack

```bash
make compose_up
make p_health          # should print "UP"
```

### 3. Create the S3 bucket

```bash
make create_bucket     # creates s3://$BUCKET with the SeaweedFS admin identity
make s3_ls             # lists the bucket (override with LS_PATH=...)
```

### 4. Create the Iceberg catalog

```bash
make p_create_catalog  # POSTs catalog.json to the management API
make p_list_catalog
```

`catalog.json` defines an `INTERNAL` catalog named `usgs`, rooted at `s3://lakehouse/usgs`. It sets two endpoints:

- `endpoint` (`localhost:8333`), which clients on the host use.
- `endpointInternal` (`s3:8333`), which Polaris uses from inside the Docker network.

It also sets `pathStyleAccess` and `stsUnavailable`, because SeaweedFS has no STS.

### 5. Set up access control for the client

```bash
make p_set_dbt_credentials
```

This target runs the Polaris RBAC chain in one go:

1. Create the **principal** `$POLARIS_PRINCIPAL`.
2. Create the **principal role** `$POLARIS_PRINCIPAL_ROLE` and assign it to the principal.
3. Create the **catalog role** `$POLARIS_CATALOG_ROLE` in the catalog.
4. Grant `CATALOG_MANAGE_CONTENT` to the catalog role.
5. Attach the catalog role to the principal role.

The response from creating the principal contains its `clientId` and `clientSecret`. Copy them into `.env` as `POLARIS_PRINCIPAL_CLIENT_ID` and `POLARIS_PRINCIPAL_CLIENT_SECRET`. To check the result:

```bash
make p_list_credentials   # principals, principal roles, catalog roles, grants
```

### 6. Run the data pipeline

```bash
make set_python_venv       # creates .venv and installs requirements.txt
make d_ingest_data_bronze  # USGS CSV → bronze parquet in SeaweedFS
make d_load_data_silver    # bronze parquet → Iceberg table via Polaris
make d_analysis            # SELECT count(*) FROM lakehouse.silver.earthquakes
```

## How DuckDB talks to Polaris

The silver and analysis scripts create two DuckDB secrets and then attach the catalog:

```sql
-- S3 credentials, used to read and write data files directly in SeaweedFS
CREATE SECRET (TYPE s3, KEY_ID '…', SECRET '…', ENDPOINT 'localhost:8333',
               URL_STYLE 'path', USE_SSL false, REGION 'us-east-1');

-- OAuth2 client credentials for the Polaris principal
CREATE SECRET polaris (TYPE iceberg, CLIENT_ID '…', CLIENT_SECRET '…',
    OAUTH2_SERVER_URI 'http://localhost:8181/api/catalog/v1/oauth/tokens',
    OAUTH2_SCOPE 'PRINCIPAL_ROLE:ALL');

-- Attach the Polaris catalog "usgs" as a DuckDB database
ATTACH 'usgs' AS lakehouse (TYPE iceberg,
    ENDPOINT 'http://localhost:8181/api/catalog',
    SECRET polaris, ACCESS_DELEGATION_MODE 'none');
```

`ACCESS_DELEGATION_MODE 'none'` tells DuckDB to use its own S3 secret instead of asking Polaris for vended credentials. That is needed here because SeaweedFS has no STS (`stsUnavailable: true` in the catalog).

## What I learned

- **Polaris has two APIs.** The **management API** (`/api/management/v1`) handles catalogs, principals, roles and grants. The **Iceberg REST API** (`/api/catalog`) handles namespaces and tables.
- **Bootstrap is a separate step.** With JDBC persistence, the realm and root credentials are created by the `polaris-admin-tool` bootstrap, not when the server starts.
- **RBAC is layered.** Principal → principal role → catalog role → privileges. A new principal can do nothing until the whole chain is in place.
- **Internal and external endpoints differ.** Polaris reaches S3 by its Docker hostname (`s3:8333`), while host clients use `localhost:8333`. The catalog's storage config needs both.
- **S3-compatible stores without STS** need `stsUnavailable` on the catalog and `ACCESS_DELEGATION_MODE 'none'` on the client.

## Teardown

```bash
docker compose down        # stop containers
docker compose down -v     # also delete the SeaweedFS and Postgres volumes
```

import os
import duckdb

conn = duckdb.connect()

conn.sql("INSTALL httpfs; LOAD httpfs; INSTALL iceberg; LOAD iceberg;")

# s3 secrect
conn.sql(f"""
CREATE SECRET (TYPE s3, KEY_ID '{os.environ["DUCKDB_S3_ACCESS_KEY"]}', SECRET '{os.environ["DUCKDB_S3_SECRET_KEY"]}',
    ENDPOINT '{os.environ["S3_ENDPOINT"]}', URL_STYLE 'path', USE_SSL false, REGION '{os.environ["AWS_REGION"]}')
""")

# iceberg secret
conn.sql(f"""
CREATE SECRET polaris (TYPE iceberg, CLIENT_ID '{os.environ["POLARIS_PRINCIPAL_CLIENT_ID"]}', CLIENT_SECRET '{os.environ["POLARIS_PRINCIPAL_CLIENT_SECRET"]}',
    OAUTH2_SERVER_URI '{os.environ["POLARIS_ENDPOINT_URL"]}/api/catalog/v1/oauth/tokens',
    OAUTH2_SCOPE 'PRINCIPAL_ROLE:ALL')
""")

conn.sql(f"""
    ATTACH 'usgs' AS lakehouse (TYPE iceberg, ENDPOINT '{os.environ["POLARIS_ENDPOINT_URL"]}/api/catalog',
        SECRET polaris, ACCESS_DELEGATION_MODE 'none')
""")
 
print(conn.sql("SELECT count(*) AS rows FROM lakehouse.silver.earthquakes").fetchall())
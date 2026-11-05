import os
import duckdb

conn = duckdb.connect()

conn.sql("INSTALL httpfs; LOAD httpfs;")

conn.sql(f"""
CREATE SECRET (TYPE s3, KEY_ID '{os.environ["DUCKDB_S3_ACCESS_KEY"]}', SECRET '{os.environ["DUCKDB_S3_SECRET_KEY"]}',
    ENDPOINT '{os.environ["S3_ENDPOINT"]}', URL_STYLE 'path', USE_SSL false, REGION '{os.environ["AWS_REGION"]}')
""")

usgs_endpoint = 'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_week.csv'

conn.sql(f"COPY (SELECT * FROM read_csv_auto('{usgs_endpoint}')) TO 's3://lakehouse/bronze/raw_data.parquet' (FORMAT parquet)")
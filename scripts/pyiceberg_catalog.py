import os
from pyiceberg.catalog.sql import SqlCatalog
import duckdb

USGS_CSV = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_week.csv"

con = duckdb.connect()
con.sql("INSTALL httpfs; LOAD httpfs;")
con.sql(f"CREATE TABLE eq AS SELECT * FROM read_csv_auto('{USGS_CSV}')")

print(con.sql("SELECT * FROM eq LIMIT 5"))

con.execute("SET TimeZone = 'UTC'")

eq_arrow_table = con.sql("SELECT * FROM eq").arrow()

cat = SqlCatalog("lab", uri="sqlite:///catalog.db", warehouse="s3://lakehouse", **{
    "s3.endpoint": "http://localhost:8333", 
    "s3.access-key-id": "lab-admin",
    "s3.secret-access-key": "lab-admin-secret-change-me",
    "s3.path-style-access": "true", 
    "s3.region": "us-east-1"})
cat.create_namespace("silver")
t = cat.create_table("silver.earthquakes", schema=eq_arrow_table.schema)
t.append(eq_arrow_table)
t.append(eq_arrow_table)  # a second commit → a second snapshot
print(t.history())
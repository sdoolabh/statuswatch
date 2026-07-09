"""One-shot migration Lambda (inside the VPC): applies schema.sql to RDS.
Exists because RDS is private — your laptop can't reach it, and that's the
point. Invoke manually after first apply:
  aws lambda invoke --function-name statuswatch-migrate /dev/stdout
Idempotent-ish: CREATE statements will error if objects exist; rerunning on
an initialized DB reports 'already exists' and that's fine.
"""
import os

import psycopg2


def lambda_handler(_event, _context):
    sql = open(os.path.join(os.path.dirname(__file__), "schema.sql")).read()
    conn = psycopg2.connect(
        host=os.environ["DB_HOST"], user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"], dbname=os.environ["DB_NAME"],
        connect_timeout=10,
    )
    conn.autocommit = True
    applied, skipped = 0, 0
    for stmt in [s.strip() for s in sql.split(";") if s.strip()]:
        with conn.cursor() as cur:
            try:
                cur.execute(stmt)
                applied += 1
            except psycopg2.errors.DuplicateObject:
                skipped += 1
            except psycopg2.errors.DuplicateTable:
                skipped += 1
    conn.close()
    print(f"applied={applied} skipped_existing={skipped}")
    return {"applied": applied, "skipped": skipped}

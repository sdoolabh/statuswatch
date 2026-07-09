# Phase 2 — the always-on pipeline in AWS

Drop-in addition to the statuswatch repo: `lambdas/`, `terraform/`, `Makefile`.
Does NOT touch your `pipeline/` directory — packaging copies your working
code (core.py, adapters/, vendors.yaml, schema.sql) into the lambda zips.

## Architecture recap
- poller Lambda (OUTSIDE VPC: free internet egress, no NAT gateway) —
  EventBridge rate(2 min) → poll 35 vendors → raw to S3 → SQS
- normalizer Lambda (INSIDE VPC: reaches private RDS; S3 via free gateway
  endpoint) — SQS → Postgres upserts → materialize status.json → data bucket
- migrate Lambda (INSIDE VPC) — one-shot schema apply, because RDS is
  deliberately unreachable from your laptop
- RDS db.t4g.micro, 7-day backups: this data IS the product
- DLQ on the queue: poison messages park for 14 days instead of looping

## Cost
RDS ~$13/mo + storage ~$2 + everything else ~$2-4 ≈ **$17-19/mo** for the
entire always-on layer. (EKS portfolio layer comes later, schedulable.)

## Runbook
```bash
# 0. one-time: state bucket (or reuse a naming scheme you like)
aws s3api create-bucket --bucket <yours>-statuswatch-tfstate --region us-east-1
aws s3api put-bucket-versioning --bucket <yours>-statuswatch-tfstate \
  --versioning-configuration Status=Enabled
# then fix the CHANGEME bucket name in terraform/main.tf

# 1. build zips from YOUR pipeline code + deploy (RDS takes ~10 min first time)
make up

# 2. initialize the schema (one-shot)
aws lambda invoke --function-name statuswatch-migrate /dev/stdout

# 3. don't wait 2 minutes — fire the poller now and watch it flow
aws lambda invoke --function-name statuswatch-poller /dev/stdout
aws s3 cp s3://$(terraform -chdir=terraform output -raw data_bucket)/status.json - | head -40
```

If step 3 shows your vendors, the pipeline is live in the sky and polling
every 2 minutes forever. Phase 3 puts CloudFront + the public site in front
of the data bucket at status.shanedoolabh.com.

## Gotchas worth knowing in advance
- `make package` needs the venv active (uses pip with Lambda-platform wheels).
- First `terraform apply` runs ~10-12 min (RDS creation dominates).
- The normalizer cold-starts a few seconds slower (VPC ENI attach) — fine.
- DB password sits in TF state + Lambda env: documented tradeoff, see
  storage.tf comment; Secrets Manager + VPC endpoint is the prod upgrade.

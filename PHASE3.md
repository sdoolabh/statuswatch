# Phase 3 — going public at status.shanedoolabh.com

Two additions: `terraform/site.tf` (drop into your existing terraform/ dir)
and `frontend/index.html` (a zero-dependency static page).

## Deploy

```bash
# 1. CloudFront + cert + DNS (cert validates in ~2-5 min; CloudFront
#    distribution deploy takes ~5-10 min — both within one apply)
terraform -chdir=terraform init -input=false   # picks up the new file
terraform -chdir=terraform apply
# expect ~9 to add: cert, validation records, validation, OAC,
# distribution, bucket policy, A + AAAA records

# 2. Upload the page into the SAME bucket the pipeline writes status.json to.
#    Long cache for the page itself; status.json keeps its own max-age=60.
aws s3 cp frontend/index.html \
  s3://$(terraform -chdir=terraform output -raw data_bucket)/index.html \
  --content-type text/html --cache-control max-age=300

# 3. Open it
open https://status.shanedoolabh.com
```

## Page updates later
Re-run step 2, then invalidate the edge cache:
```bash
aws cloudfront create-invalidation \
  --distribution-id $(terraform -chdir=terraform output -raw cloudfront_distribution_id) \
  --paths "/index.html"
```

## How freshness works (worth being able to explain)
- normalizer writes status.json with `Cache-Control: max-age=60`
- CloudFront's CachingOptimized policy honors origin headers, so edges
  re-fetch roughly once a minute
- the page re-fetches every 60s with cache:no-cache and shows "updated Xs ago"
- if generated_at goes >10 min stale, the page says so — honest degradation:
  the site stays up even if the pipeline behind it is having a bad day

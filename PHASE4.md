# Phase 4 — the EKS portfolio layer (cattle)

New: `terraform-cluster/` (separate state!), `k8s/`, `app/`,
`.github/workflows/build-images.yml`, plus `terraform/outputs_phase4.tf`
to drop into the existing persistent stack.

## What it adds
- EKS (2x spot t3.small) + ArgoCD app-of-apps from YOUR repo
- VPC peering + one SG rule = the cluster's only door into the data VPC,
  owned by cluster state (destroy revokes DB access — say that in interviews)
- FastAPI history API at api.shanedoolabh.com (+ /docs, + /metrics)
- kube-prometheus-stack; Grafana at grafana.shanedoolabh.com with your RDS
  wired as a datasource — poll_health as a live freshness dashboard
- ArgoCD UI at argocd.shanedoolabh.com
- Nightly uptime rollup as a K8s CronJob (batch on K8s, streaming on Lambda)

## Order of operations
```bash
# 0. prerequisites (one-time)
#    - repo must be PUBLIC (ArgoCD pulls it; GHCR images pull anonymously)
#    - sed the placeholders: grep -rl CHANGEME k8s/ | xargs sed -i '' 's/CHANGEME/<your-gh-user>/g'
#    - push, then run the build-images workflow once (Actions tab) and make
#      both ghcr.io packages PUBLIC (Packages -> settings)

# 1. persistent stack learns to export its facts (outputs only, no changes)
cp terraform/outputs_phase4.tf https://github.com/sdoolabh/statuswatch/terraform/
terraform -chdir=terraform apply     # plan: 0 to add/change/destroy

# 2. the cluster (~15-20 min)
cd terraform-cluster
cp terraform.tfvars.example terraform.tfvars   # set gitops_repo_url
terraform init && terraform apply

# 3. watch it converge
aws eks update-kubeconfig --name statuswatch --region us-east-1
kubectl get applications -n argocd -w     # all -> Synced/Healthy in ~5 min

# 4. the tour
open https://api.shanedoolabh.com/docs
open https://api.shanedoolabh.com/api/pipeline/health
open https://grafana.shanedoolabh.com    # admin / terraform output -raw grafana_admin_password
open https://argocd.shanedoolabh.com     # admin / kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Business-hours economics
```bash
terraform -chdir=terraform-cluster destroy   # evening: cluster + peering + DB rule gone
terraform -chdir=terraform-cluster apply     # morning: ~20 min, everything reconverges
```
Pipeline and public site never notice. ~12h/day ≈ $40-45/mo for this layer;
destroyed except for demos ≈ a few dollars.

## Known sharp edges
- First sync: API pods may CrashLoop until images are public on GHCR — fix
  package visibility, pods self-heal.
- grafana.shanedoolabh.com / argocd host values are hardcoded in two YAMLs —
  sed if your domain differs.
- DB creds flow TF remote state -> k8s Secret (not git). Prod answer: ESO ->
  Secrets Manager. Same documented tradeoff as the Lambdas — one story.

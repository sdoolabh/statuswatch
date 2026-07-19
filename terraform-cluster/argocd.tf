# Simplified bootstrap: ArgoCD + ONE Terraform-created Application (root).
# ingress-nginx moved to git (it no longer needs per-build values) and
# external-dns is retired (Terraform writes DNS). The GitOps boundary is now
# clean: Terraform owns platform bootstrap; git owns everything on top.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"

  values = [yamlencode({
    configs = {
      params = { "server.insecure" = true } # TLS terminates at the NLB
    }
  })]

  depends_on = [module.eks, kubernetes_secret.db, kubernetes_secret.grafana_admin]
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-bootstrap-apps"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "1.6.2"

  values = [yamlencode({
    applications = [{
      name      = "root"
      namespace = "argocd"
      project   = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "main"
        path           = "k8s/bootstrap"
        directory      = { recurse = true }
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
        retry = {
          limit = 5
          backoff = { duration = "30s", factor = 2, maxDuration = "5m" }
        }
      }
    }]
  })]

  depends_on = [helm_release.argocd]
}

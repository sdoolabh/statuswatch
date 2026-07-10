# Bootstrap: Terraform installs ArgoCD, then git drives everything. Two apps
# are created here (not git) because they need per-build values only
# Terraform knows: the fresh ACM cert ARN and the domain.

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

    extraObjects = [
      # ---- root app-of-apps: everything in k8s/bootstrap of your repo ----
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata   = { name = "root", namespace = "argocd" }
        spec = {
          project = "default"
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
          }
        }
      },

      # ---- ingress-nginx: needs this build's ACM cert ARN ----
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata   = { name = "platform-ingress-nginx", namespace = "argocd" }
        spec = {
          project = "default"
          source = {
            repoURL        = "https://kubernetes.github.io/ingress-nginx"
            chart          = "ingress-nginx"
            targetRevision = "4.12.1"
            helm = {
              valuesObject = {
                controller = {
                  replicaCount = 1
                  service = {
                    annotations = {
                      "service.beta.kubernetes.io/aws-load-balancer-type"             = "nlb"
                      "service.beta.kubernetes.io/aws-load-balancer-scheme"           = "internet-facing"
                      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = aws_acm_certificate_validation.wildcard.certificate_arn
                      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "443"
                      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "tcp"
                    }
                    targetPorts = { https = "http" }
                  }
                }
              }
            }
          }
          destination = { server = "https://kubernetes.default.svc", namespace = "ingress-nginx" }
          syncPolicy = {
            automated   = { prune = true, selfHeal = true }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      },

      # ---- external-dns: repoints api./grafana./argocd. every rebuild ----
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata   = { name = "platform-external-dns", namespace = "argocd" }
        spec = {
          project = "default"
          source = {
            repoURL        = "https://kubernetes-sigs.github.io/external-dns/"
            chart          = "external-dns"
            targetRevision = "1.15.2"
            helm = {
              valuesObject = {
                provider      = { name = "aws" }
                policy        = "sync"
                registry      = "txt"
                txtOwnerId    = "statuswatch"
                domainFilters = [var.domain]
                serviceAccount = { create = true, name = "external-dns" }
              }
            }
          }
          destination = { server = "https://kubernetes.default.svc", namespace = "external-dns" }
          syncPolicy = {
            automated   = { prune = true, selfHeal = true }
            syncOptions = ["CreateNamespace=true"]
          }
        }
      },
    ]
  })]

  depends_on = [module.eks, kubernetes_secret.db, kubernetes_secret.grafana_admin]
}

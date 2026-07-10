# Kubernetes-side secrets created by Terraform from remote state — the bridge
# that keeps DB credentials out of git. (Prod answer remains ESO -> Secrets
# Manager; this is the documented interim, same tradeoff as the Lambdas.)

resource "kubernetes_namespace" "statuswatch" {
  metadata { name = "statuswatch" }
  depends_on = [module.eks]
}

resource "kubernetes_secret" "db" {
  metadata {
    name      = "statuswatch-db"
    namespace = kubernetes_namespace.statuswatch.metadata[0].name
  }
  data = {
    DB_HOST     = local.p.db_host
    DB_USER     = local.p.db_user
    DB_PASSWORD = local.p.db_password
    DB_NAME     = local.p.db_name
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
  depends_on = [module.eks]
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

# Grafana sidecar picks up any secret labeled grafana_datasource and loads it:
# this wires YOUR RDS in as a datasource so poll_health becomes a dashboard.
resource "kubernetes_secret" "grafana_pg_datasource" {
  metadata {
    name      = "grafana-datasource-statuswatch"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }
  data = {
    "statuswatch-postgres.yaml" = yamlencode({
      apiVersion  = 1
      datasources = [{
        name     = "statuswatch-postgres"
        type     = "postgres"
        access   = "proxy"
        url      = "${local.p.db_host}:5432"
        user     = local.p.db_user
        database = local.p.db_name
        jsonData = { sslmode = "require", postgresVersion = 1600 }
        secureJsonData = { password = local.p.db_password }
      }]
    })
  }
}

output "grafana_admin_password_command" {
  value = "terraform output -raw grafana_admin_password"
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "urls" {
  value = {
    api     = "https://api.${var.domain}"
    grafana = "https://grafana.${var.domain}"
    argocd  = "https://argocd.${var.domain}"
  }
}

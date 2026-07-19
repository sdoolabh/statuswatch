# AWS Load Balancer Controller — installed BY TERRAFORM (not ArgoCD), because
# a Terraform-owned resource (the TargetGroupBinding below) depends on its
# CRDs and webhook existing during apply. Rule of thumb this encodes:
# cluster-bootstrap components that Terraform resources depend on live in
# Terraform; the app layer stays GitOps.
#
# One-time prerequisite (vendor the AWS-maintained policy):
#   curl -o terraform-cluster/albc-iam-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

resource "aws_iam_policy" "albc" {
  name   = "statuswatch-albc"
  policy = file("${path.module}/albc-iam-policy.json")
}

resource "aws_iam_role" "albc" {
  name = "statuswatch-albc"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "albc" {
  role       = aws_iam_role.albc.name
  policy_arn = aws_iam_policy.albc.arn
}

resource "aws_eks_pod_identity_association" "albc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.albc.arn
}

resource "helm_release" "albc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.11.0"

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = var.region
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
  })]

  # wait=true (default): apply blocks until the controller (and its webhook,
  # which validates TargetGroupBindings) is actually Ready.
  depends_on = [module.eks, aws_eks_pod_identity_association.albc]
}

# The binding: "register the endpoints of Service ingress-nginx-controller
# into the TF-owned target group, as pod IPs." Delivered via a tiny local
# chart because helm validates CRs at INSTALL time (after the ALBC release
# above guarantees the CRD exists) — unlike kubernetes_manifest, which would
# fail at PLAN time on a fresh cluster.
resource "helm_release" "tgb" {
  name             = "ingress-tgb"
  namespace        = "ingress-nginx"
  create_namespace = true
  chart            = "${path.module}/charts/tgb"

  values = [yamlencode({
    targetGroupARN = aws_lb_target_group.ingress_nginx.arn
    serviceName    = "platform-ingress-nginx-controller"
    servicePort    = 80
  })]

  depends_on = [helm_release.albc]
}

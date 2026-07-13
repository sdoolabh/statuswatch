# AWS Load Balancer Controller — IAM via Pod Identity (same pattern as
# external-dns). The controller watches Services/Ingresses and drives the
# ELB API directly: in IP mode it registers nginx POD IPs as NLB targets
# and re-registers them as pods churn (the "clerk" keeping the courier's
# address book current).
#
# The controller's IAM policy is large and AWS-maintained; vendor it rather
# than hand-writing (run once, commit the file):
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

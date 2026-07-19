# Option B: TERRAFORM owns the NLB, listener, and target group. The in-cluster
# controller (ALBC) only registers nginx pod IPs into the TF-owned target
# group via a TargetGroupBinding. Consequence: no cluster-born AWS resources
# exist, so `terraform destroy` is a pure dependency graph — orphaned-NLB
# archaeology becomes structurally impossible.

resource "aws_security_group" "nlb" {
  name   = "statuswatch-nlb"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "HTTPS from the world"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP from the world (nginx can redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "ingress" {
  name               = "statuswatch-ingress"
  internal           = false
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.nlb.id]
}

# Targets are PODS (target_type ip) — possible because the VPC CNI gives
# pods real VPC addresses. ALBC keeps the registrations current.
resource "aws_lb_target_group" "ingress_nginx" {
  name              = "statuswatch-ingress-nginx"
  port              = 80
  protocol          = "TCP"
  target_type       = "ip"
  vpc_id            = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    protocol = "TCP"
  }
}

# TLS terminates here with the per-build wildcard cert; plaintext to nginx.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.wildcard.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_nginx.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_nginx.arn
  }
}

# NLB -> pod traffic must pass the NODE security group (pods share it under
# the default CNI mode). Scoped to the NLB's SG, not a CIDR.
resource "aws_security_group_rule" "nodes_from_nlb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = aws_security_group.nlb.id
  description              = "ingress-nginx pods from the TF-owned NLB"
}

# DNS: Terraform writes the records directly — the NLB is a stable TF
# attribute, so external-dns is retired entirely. allow_overwrite lets these
# take over the records external-dns created in the old world.
resource "aws_route53_record" "apps" {
  for_each        = toset(["api", "grafana", "argocd"])
  zone_id         = data.aws_route53_zone.root.zone_id
  name            = "${each.value}.${var.domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.ingress.dns_name
    zone_id                = aws_lb.ingress.zone_id
    evaluate_target_health = false
  }
}

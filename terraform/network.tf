# Minimal private VPC: RDS + normalizer Lambda only. Deliberately NO internet
# path — no NAT gateway (~$35/mo saved), no IGW. The poller Lambda lives
# outside this VPC (Lambdas get free egress there); the normalizer's only
# external need is S3, satisfied by a FREE gateway endpoint. SQS delivery is
# handled by the Lambda service's own network, not ours.

resource "aws_vpc" "data" {
  cidr_block           = "10.61.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "statuswatch-data" }
}

resource "aws_subnet" "private" {
  for_each          = { a = "10.61.0.0/20", b = "10.61.16.0/20" }
  vpc_id            = aws_vpc.data.id
  cidr_block        = each.value
  availability_zone = "${var.region}${each.key}"
  tags              = { Name = "statuswatch-private-${each.key}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.data.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.data.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_security_group" "lambda" {
  name   = "statuswatch-lambda"
  vpc_id = aws_vpc.data.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name   = "statuswatch-rds"
  vpc_id = aws_vpc.data.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

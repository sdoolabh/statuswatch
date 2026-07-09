# Raw archive: raw-before-parse, expiring after 90 days.
resource "aws_s3_bucket" "raw" {
  bucket = "statuswatch-raw-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "expire-raw"
    status = "Enabled"
    filter { prefix = "raw/" }
    expiration { days = 90 }
  }
}

# Data bucket: the materialized status.json (CloudFront origin in Phase 3).
resource "aws_s3_bucket" "data" {
  bucket = "statuswatch-data-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The system of record gets real durability: automated backups, 7 days.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "data" {
  name       = "statuswatch"
  subnet_ids = [for s in aws_subnet.private : s.id]
}

resource "aws_db_instance" "postgres" {
  identifier     = "statuswatch"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"

  db_name  = "statuswatch"
  username = "statuswatch"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.data.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # documented cost tradeoff; prod answer: multi-AZ

  backup_retention_period = 7
  skip_final_snapshot     = false
  final_snapshot_identifier = "statuswatch-final"

  # HONEST NOTE: password lives in TF state and Lambda env vars. Acceptable
  # for a solo project with a versioned, private state bucket; the production
  # answer is Secrets Manager + rotation (needs a paid VPC interface endpoint
  # from the private subnets, ~$7/mo — a deliberate deferral, not an oversight).
}

resource "aws_sqs_queue" "observations_dlq" {
  name                      = "statuswatch-observations-dlq"
  message_retention_seconds = 1209600 # 14 days to debug poison messages
}

resource "aws_sqs_queue" "observations" {
  name                       = "statuswatch-observations"
  visibility_timeout_seconds = 120 # > normalizer timeout
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.observations_dlq.arn
    maxReceiveCount     = 3
  })
}

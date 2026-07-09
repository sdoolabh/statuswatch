# Three functions, three narrow roles. Zips come from `make package`, which
# copies your working pipeline/ code in — laptop code IS cloud code.

locals {
  lambda_env_db = {
    DB_HOST     = aws_db_instance.postgres.address
    DB_USER     = aws_db_instance.postgres.username
    DB_PASSWORD = random_password.db.result
    DB_NAME     = aws_db_instance.postgres.db_name
  }
}

# ---- IAM ----
resource "aws_iam_role" "lambda" {
  for_each = toset(["poller", "normalizer", "migrate"])
  name     = "statuswatch-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_logs" {
  for_each   = aws_iam_role.lambda
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC-attached functions need ENI management
resource "aws_iam_role_policy_attachment" "vpc_access" {
  for_each   = toset(["normalizer", "migrate"])
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "poller" {
  name = "raw-write-queue-send"
  role = aws_iam_role.lambda["poller"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.raw.arn}/raw/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:SendMessageBatch"]
        Resource = [aws_sqs_queue.observations.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "normalizer" {
  name = "queue-consume-data-write"
  role = aws_iam_role.lambda["normalizer"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.observations.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.data.arn}/*"]
      }
    ]
  })
}

# ---- functions ----
resource "aws_lambda_function" "poller" {
  function_name    = "statuswatch-poller"
  role             = aws_iam_role.lambda["poller"].arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = "${path.module}/../build/poller.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/poller.zip")
  timeout          = 90
  memory_size      = 512

  environment {
    variables = {
      RAW_BUCKET = aws_s3_bucket.raw.bucket
      QUEUE_URL  = aws_sqs_queue.observations.url
    }
  }
}

resource "aws_lambda_function" "normalizer" {
  function_name    = "statuswatch-normalizer"
  role             = aws_iam_role.lambda["normalizer"].arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = "${path.module}/../build/normalizer.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/normalizer.zip")
  timeout          = 90
  memory_size      = 256

  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.lambda_env_db, {
      DATA_BUCKET = aws_s3_bucket.data.bucket
    })
  }
}

resource "aws_lambda_function" "migrate" {
  function_name    = "statuswatch-migrate"
  role             = aws_iam_role.lambda["migrate"].arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = "${path.module}/../build/migrate.zip"
  source_code_hash = filebase64sha256("${path.module}/../build/migrate.zip")
  timeout          = 60

  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_env_db
  }
}

# ---- wiring ----
resource "aws_lambda_event_source_mapping" "normalizer" {
  event_source_arn                   = aws_sqs_queue.observations.arn
  function_name                      = aws_lambda_function.normalizer.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
}

resource "aws_cloudwatch_event_rule" "poll" {
  name                = "statuswatch-poll"
  schedule_expression = "rate(${var.poll_rate_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "poll" {
  rule = aws_cloudwatch_event_rule.poll.name
  arn  = aws_lambda_function.poller.arn
}

resource "aws_lambda_permission" "poll" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.poller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.poll.arn
}

# keep log costs sane from day one
resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = toset(["poller", "normalizer", "migrate"])
  name              = "/aws/lambda/statuswatch-${each.key}"
  retention_in_days = 30
}

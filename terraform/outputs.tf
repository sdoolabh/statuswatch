output "raw_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "queue_url" {
  value = aws_sqs_queue.observations.url
}

output "smoke_test_commands" {
  value = <<-EOT
    1. aws lambda invoke --function-name statuswatch-migrate /dev/stdout
    2. aws lambda invoke --function-name statuswatch-poller /dev/stdout
    3. aws s3 cp s3://${aws_s3_bucket.data.bucket}/status.json - | head -40
  EOT
}

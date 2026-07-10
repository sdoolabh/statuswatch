# DROP THIS FILE INTO YOUR EXISTING terraform/ (persistent stack) and
# `terraform apply` once (outputs only — zero infrastructure changes).
# The cluster stack reads these via terraform_remote_state; it's the contract
# between the persistent world and the destroyable one.

output "data_vpc_id" {
  value = aws_vpc.data.id
}

output "data_vpc_cidr" {
  value = aws_vpc.data.cidr_block
}

output "data_private_route_table_id" {
  value = aws_route_table.private.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "db_host" {
  value = aws_db_instance.postgres.address
}

output "db_user" {
  value = aws_db_instance.postgres.username
}

output "db_name" {
  value = aws_db_instance.postgres.db_name
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

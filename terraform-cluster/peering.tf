# The one new door into the sealed data VPC. Lives in THIS stack so that
# destroying the cluster provably removes database access.

resource "aws_vpc_peering_connection" "cluster_to_data" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = local.p.data_vpc_id
  auto_accept = true # same account, same region
  tags        = { Name = "statuswatch-cluster-to-data" }
}

# Route from every cluster public subnet -> data VPC
resource "aws_route" "cluster_to_data" {
  count                     = length(module.vpc.public_route_table_ids)
  route_table_id            = module.vpc.public_route_table_ids[count.index]
  destination_cidr_block    = local.p.data_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_data.id
}

# Return route: data VPC -> cluster VPC
resource "aws_route" "data_to_cluster" {
  route_table_id            = local.p.data_private_route_table_id
  destination_cidr_block    = module.vpc.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.cluster_to_data.id
}

# Open 5432 from cluster nodes to RDS — attached to the PERSISTENT SG but
# owned by THIS state: cluster destroy revokes it automatically.
resource "aws_security_group_rule" "rds_from_cluster" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  security_group_id = local.p.rds_security_group_id
  cidr_blocks       = [module.vpc.vpc_cidr_block]
  description       = "statuswatch EKS cluster (removed on cluster destroy)"
}

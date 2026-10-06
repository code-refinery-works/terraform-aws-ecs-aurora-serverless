output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}
output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = aws_ecs_cluster.main.name
}
output "aurora_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.main.endpoint
}
output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.main.reader_endpoint
}
output "db_secret_arn" {
  description = "Secrets Manager ARN for DB master password"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
output "app_url" {
  description = "Set as GitHub variable APP_URL"
  value       = "http://${aws_eip.app.public_ip}"
}

output "grafana_url" {
  value = "http://${aws_eip.app.public_ip}:3000"
}

output "ec2_instance_id" {
  description = "Set as GitHub variable EC2_INSTANCE_ID"
  value       = aws_instance.app.id
}

output "github_deploy_role_arn" {
  description = "Set as GitHub secret AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.github_deploy.arn
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.endpoint
}

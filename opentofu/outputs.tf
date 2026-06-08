output "api_endpoint" {
  description = "HTTPS base URL of the public API Gateway endpoint."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "api_verify_carrier_url" {
  description = "Full URL for the carrier-verification endpoint."
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/carriers/verify"
}

output "api_loads_url" {
  description = "Full URL for the load-search endpoint."
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/loads"
}

output "api_metrics_url" {
  description = "Full URL for the metrics ingestion endpoint."
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/metrics"
}

output "ecr_repository_url" {
  description = "ECR repository URL (use this to push Lambda container images)."
  value       = aws_ecr_repository.lambda_api.repository_url
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function."
  value       = aws_lambda_function.api.function_name
}

output "loads_bucket_name" {
  description = "S3 bucket that stores the loads catalogue (loads.json)."
  value       = aws_s3_bucket.loads.id
}

output "fmcsa_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the FMCSA API key."
  value       = aws_secretsmanager_secret.fmcsa_api_key.arn
}

output "api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the load-sales API key."
  value       = aws_secretsmanager_secret.api_key.arn
}

output "cloudwatch_dashboard_url" {
  description = "Direct link to the CloudWatch operations dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "lambda_log_group" {
  description = "CloudWatch Log Group for the Lambda function."
  value       = aws_cloudwatch_log_group.lambda_api.name
}

output "api_gateway_id" {
  description = "API Gateway HTTP API identifier."
  value       = aws_apigatewayv2_api.main.id
}

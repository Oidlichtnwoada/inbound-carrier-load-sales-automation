# =============================================================================
# Locals
# =============================================================================
locals {
  name_prefix      = var.app_name
  custom_namespace = "InboundCarrierSales/Calls"
  lambda_build_strategy = "buildx-load-v1"

  # Deterministic image tag: changes whenever app.py or Dockerfile changes,
  # which forces Terraform to rebuild & push the image and update the Lambda.
  lambda_src_hash = substr(
    md5(join("", [
      filemd5("${path.module}/../lambda/app.py"),
      filemd5("${path.module}/../lambda/Dockerfile"),
      filemd5("${path.module}/../lambda/requirements.txt"),
    ])),
    0, 12
  )
  lambda_image_tag = "build-${local.lambda_src_hash}"
  lambda_src_dir   = "${path.module}/../lambda"
  loads_s3_key     = "loads/loads.json"
}

# =============================================================================
# S3 - loads catalogue bucket
# =============================================================================
resource "aws_s3_bucket" "loads" {
  bucket        = "${local.name_prefix}-loads-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "loads" {
  bucket = aws_s3_bucket.loads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loads" {
  bucket = aws_s3_bucket.loads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loads" {
  bucket                  = aws_s3_bucket.loads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "loads" {
  bucket       = aws_s3_bucket.loads.id
  key          = local.loads_s3_key
  source       = "${path.module}/loads.json"
  content_type = "application/json"
  etag         = filemd5("${path.module}/loads.json")

  depends_on = [aws_s3_bucket_public_access_block.loads]
}

# =============================================================================
# AWS Secrets Manager - FMCSA key & API key
# =============================================================================
resource "aws_secretsmanager_secret" "fmcsa_api_key" {
  name                    = "${local.name_prefix}/fmcsa-api-key"
  description             = "FMCSA Query Central web-service API key."
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "fmcsa_api_key" {
  secret_id     = aws_secretsmanager_secret.fmcsa_api_key.id
  secret_string = var.fmcsa_api_key
}

resource "aws_secretsmanager_secret" "api_key" {
  name                    = "${local.name_prefix}/api-key"
  description             = "API key for authenticating inbound requests to the load-sales API."
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id     = aws_secretsmanager_secret.api_key.id
  secret_string = var.api_key
}

# =============================================================================
# ECR - container repository for the Lambda image
# =============================================================================
resource "aws_ecr_repository" "lambda_api" {
  name                 = "${local.name_prefix}-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_repository_policy" "lambda_api" {
  repository = aws_ecr_repository.lambda_api.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "LambdaECRImageRetrievalPolicy"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Condition = {
        StringLike = {
          "aws:sourceArn" = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.name_prefix}-api"
        }
      }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "lambda_api" {
  repository = aws_ecr_repository.lambda_api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain only the 5 most recent images to control storage costs."
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# =============================================================================
# Docker build & push (triggered by source-hash changes)
# =============================================================================
resource "null_resource" "docker_build_push" {
  triggers = {
    image_tag       = local.lambda_image_tag
    build_strategy  = local.lambda_build_strategy
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      echo "==> Authenticating with ECR…"
      aws ecr get-login-password --region "${var.aws_region}" \
        | docker login --username AWS --password-stdin \
          "${aws_ecr_repository.lambda_api.registry_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

      echo "==> Building image (linux/amd64)…"
      docker buildx build \
        --platform linux/amd64 \
        --pull \
        --provenance=false \
        --sbom=false \
        --load \
        --tag "${aws_ecr_repository.lambda_api.repository_url}:${local.lambda_image_tag}" \
        "${local.lambda_src_dir}"

      echo "==> Pushing image…"
      docker push "${aws_ecr_repository.lambda_api.repository_url}:${local.lambda_image_tag}"

      echo "==> Done. Image: ${aws_ecr_repository.lambda_api.repository_url}:${local.lambda_image_tag}"
    EOT
  }

  depends_on = [aws_ecr_repository.lambda_api]
}

# =============================================================================
# IAM - Lambda execution role
# =============================================================================
resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_custom" {
  name = "${local.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3LoadsRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.loads.arn}/*"]
      },
      {
        Sid    = "SecretsRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.fmcsa_api_key.arn,
          aws_secretsmanager_secret.api_key.arn,
        ]
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRImagePull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = ["*"]
      },
    ]
  })
}

# =============================================================================
# CloudWatch - log groups
# =============================================================================
resource "aws_cloudwatch_log_group" "lambda_api" {
  name              = "/aws/lambda/${local.name_prefix}-api"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = 30
}

# =============================================================================
# Lambda function
# =============================================================================
resource "aws_lambda_function" "api" {
  function_name = "${local.name_prefix}-api"
  role          = aws_iam_role.lambda_exec.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda_api.repository_url}:${local.lambda_image_tag}"
  architectures = ["x86_64"]
  timeout       = 30
  memory_size   = 512

  environment {
    variables = {
      LOADS_BUCKET           = aws_s3_bucket.loads.id
      LOADS_KEY              = local.loads_s3_key
      FMCSA_SECRET_ARN       = aws_secretsmanager_secret.fmcsa_api_key.arn
      API_KEY_SECRET_ARN     = aws_secretsmanager_secret.api_key.arn
      CLOUDWATCH_NAMESPACE   = local.custom_namespace
      EMPLOYEE_COST_PER_HOUR = tostring(var.employee_cost_per_hour)
    }
  }

  depends_on = [
    null_resource.docker_build_push,
    aws_cloudwatch_log_group.lambda_api,
    aws_iam_role_policy_attachment.lambda_basic_exec,
    aws_iam_role_policy.lambda_custom,
  ]
}

# =============================================================================
# API Gateway v2 - HTTP API (HTTPS, public)
# =============================================================================
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "Inbound Carrier Load Sales Automation - public API"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type", "X-Api-Key"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      sourceIp         = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_burst_limit   = 200
    throttling_rate_limit    = 100
    detailed_metrics_enabled = true
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "verify_carrier" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /carriers/verify"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "search_loads" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /loads"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "save_metrics" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /metrics"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "apigateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# =============================================================================
# Data sources
# =============================================================================
data "aws_caller_identity" "current" {}

# =============================================================================
# CloudWatch Dashboard - Business & Infrastructure Metrics
# =============================================================================
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-operations"

  dashboard_body = jsonencode({
    widgets = [

      # ── Section header: Business Performance ──────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "## 📦 Inbound Carrier Sales - Business Performance"
        }
      },

      # ── KPI: Total Deal Value Today ───────────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 5
        height = 5
        properties = {
          region = var.aws_region
          title                = "💰 Total Deal Value Today (USD)"
          view                 = "singleValue"
          stat                 = "Sum"
          period               = 86400
          setPeriodToTimeRange = true
          metrics = [
            [local.custom_namespace, "DealValue", { label = "USD" }]
          ]
        }
      },

      # ── KPI: Deals Closed Today ───────────────────────────────────────────
      {
        type   = "metric"
        x      = 5
        y      = 1
        width  = 4
        height = 5
        properties = {
          region = var.aws_region
          title                = "✅ Deals Closed Today"
          view                 = "singleValue"
          stat                 = "Sum"
          period               = 86400
          setPeriodToTimeRange = true
          metrics = [
            [local.custom_namespace, "SuccessfulDeals", { label = "Deals" }]
          ]
        }
      },

      # ── KPI: Call Success Rate ────────────────────────────────────────────
      {
        type   = "metric"
        x      = 9
        y      = 1
        width  = 5
        height = 5
        properties = {
          region = var.aws_region
          title                = "📊 Call Success Rate (%)"
          view                 = "singleValue"
          period               = 86400
          setPeriodToTimeRange = true
          metrics = [
            [local.custom_namespace, "SuccessfulDeals", { id = "m1", visible = false, stat = "Sum" }],
            [local.custom_namespace, "CarrierCallsTotal", { id = "m2", visible = false, stat = "Sum" }],
            [{ expression = "IF(m2>0,(m1/m2)*100,0)", label = "Success Rate %", id = "e1" }]
          ]
        }
      },

      # ── KPI: Employee Cost Saved Today ────────────────────────────────────
      {
        type   = "metric"
        x      = 14
        y      = 1
        width  = 5
        height = 5
        properties = {
          region = var.aws_region
          title                = "🏦 Employee Cost Saved Today (USD)"
          view                 = "singleValue"
          stat                 = "Sum"
          period               = 86400
          setPeriodToTimeRange = true
          metrics = [
            [local.custom_namespace, "EmployeeCostSaved", { label = "USD" }]
          ]
        }
      },

      # ── KPI: Time Saved Today ─────────────────────────────────────────────
      {
        type   = "metric"
        x      = 19
        y      = 1
        width  = 5
        height = 5
        properties = {
          region = var.aws_region
          title                = "⏱ Agent Time Saved Today (min)"
          view                 = "singleValue"
          stat                 = "Sum"
          period               = 86400
          setPeriodToTimeRange = true
          metrics = [
            [local.custom_namespace, "TimeSavedMinutes", { label = "Minutes" }]
          ]
        }
      },

      # ── Section header: Trends ────────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 6
        width  = 24
        height = 1
        properties = {
          markdown = "## 📈 Revenue & Volume Trends"
        }
      },

      # ── Chart: Deal Value Trend (7 days) ──────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 7
        properties = {
          region = var.aws_region
          title   = "Deal Value per Hour (last 7 days)"
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = 3600
          metrics = [
            [local.custom_namespace, "DealValue", { label = "Deal Value USD", color = "#2ca02c" }]
          ]
          yAxis  = { left = { label = "USD", showUnits = false } }
          legend = { position = "bottom" }
        }
      },

      # ── Chart: Call Volume Breakdown (7 days) ─────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 7
        properties = {
          region = var.aws_region
          title   = "Call Volume - Outcomes (last 7 days)"
          view    = "timeSeries"
          stacked = true
          stat    = "Sum"
          period  = 3600
          metrics = [
            [local.custom_namespace, "SuccessfulDeals", { label = "Successful", color = "#2ca02c" }],
            [local.custom_namespace, "UnsuccessfulCalls", { label = "Unsuccessful", color = "#d62728" }],
          ]
          yAxis  = { left = { label = "Calls", showUnits = false } }
          legend = { position = "bottom" }
        }
      },

      # ── Section header: Call Quality & ROI ───────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 14
        width  = 24
        height = 1
        properties = {
          markdown = "## 📞 Call Quality & ROI"
        }
      },

      # ── Gauge: Average Carrier Sentiment ─────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 6
        height = 6
        properties = {
          region = var.aws_region
          title  = "😊 Avg Carrier Sentiment (1-5)"
          view   = "gauge"
          stat   = "Average"
          period = 86400
          metrics = [
            [local.custom_namespace, "CarrierSentiment", { label = "Sentiment Score" }]
          ]
          yAxis = { left = { min = 1, max = 5 } }
        }
      },

      # ── Single value: Average Call Duration ───────────────────────────────
      {
        type   = "metric"
        x      = 6
        y      = 15
        width  = 6
        height = 6
        properties = {
          region = var.aws_region
          title  = "⏰ Avg Call Duration (min)"
          view   = "singleValue"
          stat   = "Average"
          period = 86400
          metrics = [
            [local.custom_namespace, "CallDurationMinutes", { label = "Minutes" }]
          ]
        }
      },

      # ── Chart: Cumulative Cost & Time Savings ─────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 15
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title   = "💼 Cumulative Savings (last 7 days)"
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = 3600
          metrics = [
            [local.custom_namespace, "EmployeeCostSaved", { label = "Cost Saved (USD)", color = "#1f77b4", yAxis = "left" }],
            [local.custom_namespace, "TimeSavedMinutes", { label = "Time Saved (min)", color = "#ff7f0e", yAxis = "right" }],
          ]
          yAxis = {
            left  = { label = "USD", showUnits = false }
            right = { label = "Minutes", showUnits = false }
          }
          legend = { position = "bottom" }
        }
      },

      # ── Section header: Infrastructure Health ────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 21
        width  = 24
        height = 1
        properties = {
          markdown = "## ⚙️ Infrastructure Health"
        }
      },

      # ── Chart: Lambda Invocations & Errors ───────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 22
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title   = "Lambda - Invocations & Errors"
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.api.function_name, { label = "Invocations", color = "#1f77b4" }],
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.api.function_name, { label = "Errors", color = "#d62728" }],
            ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.api.function_name, { label = "Throttles", color = "#ff7f0e" }],
          ]
          yAxis  = { left = { label = "Count", showUnits = false } }
          legend = { position = "bottom" }
        }
      },

      # ── Chart: Lambda Duration (p50/p95/p99) ─────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 22
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title   = "Lambda - Execution Duration (ms)"
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.api.function_name, { stat = "p50", label = "p50", color = "#2ca02c" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.api.function_name, { stat = "p95", label = "p95", color = "#ff7f0e" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.api.function_name, { stat = "p99", label = "p99", color = "#d62728" }],
          ]
          yAxis  = { left = { label = "ms", showUnits = false } }
          legend = { position = "bottom" }
        }
      },

      # ── Chart: API Gateway Requests & 4xx/5xx ────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 28
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title   = "API Gateway - Request Volume & Errors"
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id, { label = "Total Requests", color = "#1f77b4" }],
            ["AWS/ApiGateway", "4XXError", "ApiId", aws_apigatewayv2_api.main.id, { label = "4xx Errors", color = "#ff7f0e" }],
            ["AWS/ApiGateway", "5XXError", "ApiId", aws_apigatewayv2_api.main.id, { label = "5xx Errors", color = "#d62728" }],
          ]
          yAxis  = { left = { label = "Count", showUnits = false } }
          legend = { position = "bottom" }
        }
      },

      # ── Chart: API Gateway Latency ────────────────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 28
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title   = "API Gateway - Latency (ms)"
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.main.id, { stat = "p50", label = "p50", color = "#2ca02c" }],
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.main.id, { stat = "p95", label = "p95", color = "#ff7f0e" }],
            ["AWS/ApiGateway", "IntegrationLatency", "ApiId", aws_apigatewayv2_api.main.id, { stat = "p95", label = "Integration p95", color = "#9467bd" }],
          ]
          yAxis  = { left = { label = "ms", showUnits = false } }
          legend = { position = "bottom" }
        }
      },

    ]
  })
}

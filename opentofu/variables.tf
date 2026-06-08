variable "fmcsa_api_key" {
  description = "FMCSA Query Central web-service API key used for carrier verification. Obtain at https://mobile.fmcsa.dot.gov/QCDevsite/"
  type        = string
  sensitive   = true
}

variable "api_key" {
  description = "API key that callers must supply in the X-Api-Key header when calling the load-sales API."
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Application name used as a prefix for all AWS resource names."
  type        = string
  default     = "inbound-carrier-sales"
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "state_bucket_name" {
  description = "Name of the pre-existing S3 bucket used for OpenTofu remote state. Must match the bucket configured in provider.tf backend block."
  type        = string
  default     = "inbound-carrier-tofu-state"
}

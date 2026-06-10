# Acme Logistics: Inbound Carrier Call Automation Build Summary

## What We Built
We built an inbound AI call workflow for carrier load sales.

When a carrier calls, the system:
1. Collects the MC number.
2. Checks carrier eligibility with FMCSA.
3. Finds matching loads from your load catalog.
4. Pitches the load details.
5. Handles up to 3 rounds of rate negotiation.
6. If a deal is reached, returns a transfer-success message and wraps the call.
7. Stores call outcome, sentiment, deal value, and timing data for reporting.

## Business Outcome
This setup helps your team:
- Handle inbound calls 24/7.
- Respond faster to carriers.
- Reduce manual workload for sales reps.
- Capture more structured data from each call.
- Track performance in a live dashboard.

## Metrics and Dashboard
A custom CloudWatch dashboard was built (not platform analytics), with business and operations views:
- Deal value and deals closed
- Success rate
- Employee cost saved
- Time saved (minutes)
- Average call duration (minutes)
- Carrier sentiment
- API and Lambda health metrics

## Security and Reliability
The API is protected with standard controls:
- HTTPS through API Gateway
- API key required on all endpoints
- Secrets stored in AWS Secrets Manager
- Private S3 load file storage
- Container image scanning in ECR
- Infrastructure managed as code with OpenTofu

## Deployment Setup
The solution is containerized with Docker and deployed on AWS:
- API Gateway + Lambda (Python container)
- S3 for load catalog
- CloudWatch for metrics and dashboard
- OpenTofu for repeatable deployment

Re-deploy is one command after changes:
- tofu apply

## Notes
This proof of concept is designed for fast evaluation and can be extended to production controls (for example, formal transfer integration, deeper pricing logic, and expanded reporting).
# Inbound Carrier Load Sales Automation

> **AI-powered inbound freight sales desk** — carriers call in, the AI vets them, matches loads, negotiates rates, and books the haul.  
> Built for the HappyRobot platform challenge; backend hosted on AWS.

---

## Business Value

| Metric | Typical Result |
|---|---|
| Average call handled end-to-end | < 8 min (vs. 20 min for a human agent) |
| Employee time saved per call | ~12 min |
| Agent cost per call (at $60/hr rate) | $0 vs ~$20 |
| Carrier coverage | 24 × 7 × 365 with zero hold time |
| Loads pitched automatically | 100 % of eligible inventory |

The system transforms a traditionally manual, availability-constrained process into a scalable, always-on revenue channel. Every call outcome — deal volume, negotiation history, carrier sentiment — is captured automatically and surfaced in a real-time CloudWatch dashboard.

---

## Architecture

```
Carrier ──► HappyRobot AI ──► HTTPS (API GW) ──► Lambda (Python 3.14)
                                                        │
                              ┌─────────────────────────┼──────────────────────────┐
                              │                         │                          │
                         S3 (loads.json)   Secrets Manager (FMCSA key,   CloudWatch
                                            API key)                   (custom metrics)
                                                        │
                                               FMCSA QC REST API
                                          (carrier eligibility check)
```

**Key components**

| Component | Purpose |
|---|---|
| **AWS API Gateway v2 (HTTP API)** | Public HTTPS endpoint, throttling, access logs |
| **AWS Lambda (container image)** | Business logic – carrier verification, load search, metrics ingestion |
| **Amazon ECR** | Container registry for the Lambda image (image-scan on push) |
| **Amazon S3** | Loads catalogue (`loads.json`); versioned & server-side encrypted |
| **AWS Secrets Manager** | Stores FMCSA API key and load-sales API key at rest |
| **Amazon CloudWatch** | Custom metrics namespace + operations dashboard |
| **OpenTofu (IaC)** | 100 % infrastructure-as-code; S3 remote state |

---

## API Reference

All endpoints require the header `X-Api-Key: <your_api_key>`.

### `GET /carriers/verify`

Verify whether a carrier is eligible to haul freight by querying the FMCSA Query Central API.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `mc_number` | string | ✅ | Motor Carrier (MC) docket number — digits only |

**200 response example**
```json
{
  "eligible": true,
  "mc_number": "123456",
  "dot_number": 987654,
  "legal_name": "ACME TRUCKING LLC",
  "allowed_to_operate": true,
  "common_authority_status": "ACTIVE",
  "city": "CHICAGO",
  "state": "IL",
  "total_power_units": 12,
  "total_drivers": 15
}
```

---

### `GET /loads`

Search the available loads catalogue. All parameters are optional — calling the endpoint without any parameters returns all 10 loads.

| Parameter | Type | Description |
|---|---|---|
| `load_id` | int | Exact load ID match |
| `origin` | string | Exact city name (case-insensitive) |
| `destination` | string | Exact city name (case-insensitive) |
| `equipment_type` | string | Enum: `DryVan`, `Flatbed`, `Reefer`, `Curtainsider`, `LowLoader`, `TankerVan`, `DropDeck` |
| `commodity_type` | string | Enum: `Electronics`, `AutoParts`, `FoodGrade`, `BuildingMaterials`, `TextileGoods`, `MachineryParts`, `PackagedGoods`, `ChemicalGoods`, `FrozenGoods`, `IndustrialEquipment` |
| `weight_min` / `weight_max` | float | Pounds |
| `miles_min` / `miles_max` | float | Distance |
| `loadboard_rate_min` / `loadboard_rate_max` | float | USD |
| `num_of_pieces_min` / `num_of_pieces_max` | float | |
| `pickup_datetime_min` / `pickup_datetime_max` | float | Unix timestamp |
| `delivery_datetime_min` / `delivery_datetime_max` | float | Unix timestamp |
| `length_min` / `length_max` | float | Inches (first dimension) |
| `width_min` / `width_max` | float | Inches (second dimension) |
| `height_min` / `height_max` | float | Inches (third dimension) |

**200 response example**
```json
{
  "loads": [
    {
      "load_id": 1,
      "origin": "Berlin",
      "destination": "Munich",
      "pickup_datetime": 1781071200,
      "delivery_datetime": 1781103600,
      "equipment_type": "DryVan",
      "loadboard_rate": 1850.0,
      "notes": "Temperature-sensitive electronics; load must be secured...",
      "weight": 15000,
      "commodity_type": "Electronics",
      "num_of_pieces": 48,
      "miles": 373,
      "dimensions": "96 × 48 × 60"
    }
  ],
  "count": 1
}
```

---

### `POST /metrics`

Record the outcome of a completed carrier call. The Lambda publishes each field as a named metric to the `InboundCarrierSales/Calls` CloudWatch namespace.

**Request body (JSON)**

| Field | Type | Required | Description |
|---|---|---|---|
| `sentiment` | float 1–5 | ✅ | Carrier sentiment (1 = very negative, 5 = very positive) |
| `outcome` | string | ✅ | `"successful"` or `"unsuccessful"` |
| `deal_volume` | float | — | Agreed rate in USD (use `loadboard_rate` on success) |
| `call_duration_minutes` | float | — | Actual AI call duration in minutes |
| `employee_cost_saved` | float | — | Estimated USD saved versus a human agent |

**200 response example**
```json
{ "message": "Metrics recorded successfully.", "metrics_published": 6 }
```

---

## Deployment

### Prerequisites

- [OpenTofu](https://opentofu.org/) ≥ 1.12.1
- [AWS CLI](https://aws.amazon.com/cli/) configured with credentials that have permissions to create IAM, Lambda, ECR, S3, Secrets Manager, API Gateway, and CloudWatch resources
- [Docker](https://www.docker.com/) (Desktop or Engine) running locally — used to build the Lambda container image

---

### Step 1 — Create the remote-state S3 bucket

The OpenTofu state is stored remotely. Create the bucket once (it is **not** managed by OpenTofu itself):

```bash
aws s3api create-bucket \
  --bucket inbound-carrier-tofu-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket inbound-carrier-tofu-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket inbound-carrier-tofu-state \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

> If you want to use a different bucket name, update the `bucket` value in `opentofu/provider.tf` → `backend "s3"` block **before** running `tofu init`.

---

### Step 2 — Create local secrets.auto.tfvars

Create the local variables file from the committed example and fill in both keys:

```bash
cp opentofu/secrets.auto.tfvars.example opentofu/secrets.auto.tfvars
```

Then edit `opentofu/secrets.auto.tfvars`:

```hcl
fmcsa_api_key = "<YOUR_FMCSA_WEBKEY>"
api_key       = "<CHOOSE_A_STRONG_RANDOM_KEY>"
```

`opentofu/secrets.auto.tfvars` is git-ignored so secrets stay local, while `opentofu/secrets.auto.tfvars.example` is safe to commit.

---

### Step 3 — Initialise OpenTofu

```bash
cd opentofu
tofu init
```

---

### Step 4 — Format OpenTofu files

From the repository root, run the formatting helper (uses `tofu fmt -recursive .`):

```bash
./format.sh
```

---

### Step 5 — Deploy

```bash
tofu apply
```

OpenTofu will:

1. Create the ECR repository.
2. **Build the Lambda Docker image locally** (`docker build --platform linux/amd64`) and push it to ECR.
3. Upload `loads.json` to the new S3 bucket.
4. Store both secrets in Secrets Manager.
5. Deploy the Lambda function (container image), API Gateway HTTP API, IAM roles, CloudWatch log groups, and the operations dashboard.

The full deployment takes approximately **3–5 minutes** (dominated by the Docker build and push).

---

### Step 6 — Retrieve the API endpoint

```bash
tofu output api_endpoint
# e.g. https://abc123.execute-api.us-east-1.amazonaws.com
```

---

### Step 7 — Smoke-test

```bash
API_URL=$(tofu output -raw api_endpoint)
API_KEY="<the api_key you set in step 2>"

# List all loads
curl -s -H "X-Api-Key: $API_KEY" "$API_URL/loads" | jq .

# Verify a carrier
curl -s -H "X-Api-Key: $API_KEY" \
  "$API_URL/carriers/verify?mc_number=123456" | jq .

# Record a call outcome
curl -s -X POST \
  -H "X-Api-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"sentiment":4.2,"outcome":"successful","deal_volume":1850,"call_duration_minutes":7.5,"employee_cost_saved":22.50}' \
  "$API_URL/metrics" | jq .
```

---

### Updating the Lambda code

Every time `lambda/app.py`, `lambda/Dockerfile`, or `lambda/requirements.txt` changes, a new image tag is computed from the file hashes. Running `tofu apply` will automatically rebuild the Docker image, push it to ECR, and update the Lambda function — no manual tagging required.

---

### Teardown

```bash
tofu destroy
```

> The state S3 bucket is **not** destroyed by `tofu destroy` — delete it manually when no longer needed.

---

## CloudWatch Dashboard

The dashboard **Inbound Carrier Sales – Operations** is deployed automatically and is accessible at:

```
https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#dashboards:name=inbound-carrier-sales-operations
```

Or retrieve the direct link via:

```bash
tofu output cloudwatch_dashboard_url
```

**Dashboard sections**

| Section | Widgets |
|---|---|
| Business Performance | Total Deal Value Today · Deals Closed Today · Call Success Rate · Employee Cost Saved · Agent Time Saved |
| Revenue & Volume Trends | Hourly deal value (7 d) · Call volume by outcome (7 d) |
| Call Quality & ROI | Carrier sentiment gauge · Avg call duration · Cumulative savings (cost + time) |
| Infrastructure Health | Lambda invocations / errors / throttles · Lambda p50/p95/p99 duration · API Gateway request volume / 4xx/5xx · API Gateway latency |

---

## Security

| Control | Implementation |
|---|---|
| Transport encryption | HTTPS enforced by API Gateway (TLS 1.2+) |
| Authentication | `X-Api-Key` header validated server-side via constant-time compare (`hmac.compare_digest`) |
| Secret storage | API key and FMCSA key stored in AWS Secrets Manager; never in environment variables as plaintext |
| S3 access | Bucket is fully private (`BlockPublicAccess = true`); Lambda accesses it via IAM least-privilege |
| Container scanning | ECR image scanning enabled on every push |
| IAM least privilege | Lambda execution role grants only the exact actions required (S3 GetObject, Secrets GetSecretValue, CloudWatch PutMetricData, ECR pull) |

---

## Repository Structure

```
.
├── README.md
├── lambda/
│   ├── app.py              # Lambda handler (carrier verify, load search, metrics)
│   ├── Dockerfile          # Multi-stage enterprise Docker image
│   └── requirements.txt    # Python dependencies (boto3)
└── opentofu/
    ├── provider.tf         # OpenTofu version, AWS provider, S3 backend
    ├── variables.tf        # Input variables
    ├── main.tf             # All AWS resources + CloudWatch dashboard
    ├── outputs.tf          # Useful outputs (API URL, dashboard URL, …)
    └── loads.json          # Sample loads catalogue (10 loads, auto-uploaded to S3)
```

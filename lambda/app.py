"""
Inbound Carrier Sales Automation - Lambda API Handler
======================================================
Endpoints
---------
GET  /carriers/verify   Verify a carrier MC number via the FMCSA QC REST API.
GET  /loads             Search the available loads catalogue with rich filters.
POST /metrics           Record call outcome metrics → published to CloudWatch.

Authentication
--------------
Every request must include the header:
    X-Api-Key: <api_key>
The key is validated against the value stored in AWS Secrets Manager.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, cast

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Environment - injected by Lambda / Terraform
# ---------------------------------------------------------------------------
LOADS_BUCKET: str = os.environ["LOADS_BUCKET"]
LOADS_KEY: str = os.environ["LOADS_KEY"]
FMCSA_SECRET_ARN: str = os.environ["FMCSA_SECRET_ARN"]
API_KEY_SECRET_ARN: str = os.environ["API_KEY_SECRET_ARN"]
CLOUDWATCH_NAMESPACE: str = os.environ.get(
    "CLOUDWATCH_NAMESPACE", "InboundCarrierSales/Calls"
)
EMPLOYEE_COST_PER_HOUR: float = float(os.environ.get("EMPLOYEE_COST_PER_HOUR", "50"))

# ---------------------------------------------------------------------------
# AWS clients (module-level → reused across warm invocations)
# ---------------------------------------------------------------------------
_secretsmanager = boto3.client("secretsmanager")
_s3 = boto3.client("s3")
_cloudwatch = boto3.client("cloudwatch")

# ---------------------------------------------------------------------------
# In-memory caches (warm-invocation optimisation)
# Using a mutable container avoids module-level rebinding (no global needed).
# ---------------------------------------------------------------------------
_secrets_cache: dict[str, str] = {}
_cache: dict[str, list[dict] | None] = {"loads": None}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_secret(secret_arn: str) -> str:
    """Return the plaintext value of a Secrets Manager secret, cached."""
    if secret_arn not in _secrets_cache:
        response = _secretsmanager.get_secret_value(SecretId=secret_arn)
        _secrets_cache[secret_arn] = response["SecretString"]
    return _secrets_cache[secret_arn]


def _get_loads() -> list[dict]:
    """Return the loads catalogue from S3, cached for the lifetime of the container."""
    if _cache["loads"] is None:
        obj = _s3.get_object(Bucket=LOADS_BUCKET, Key=LOADS_KEY)
        _cache["loads"] = json.loads(obj["Body"].read().decode("utf-8"))
    return cast(list[dict], _cache["loads"])


def _response(status_code: int, body: dict[str, Any]) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "X-Content-Type-Options": "nosniff",
        },
        "body": json.dumps(body),
    }


def _authenticate(event: dict) -> bool:
    """Return True when the X-Api-Key header matches the stored API key."""
    headers: dict = event.get("headers") or {}
    provided = headers.get("x-api-key") or headers.get("X-Api-Key") or ""
    try:
        expected = _get_secret(API_KEY_SECRET_ARN)
    except Exception:
        logger.exception("Failed to retrieve API key secret")
        return False
    # Constant-time comparison guard against timing attacks
    import hmac
    return hmac.compare_digest(provided, expected)


def _parse_dimensions(dimensions: str) -> tuple[float, float, float]:
    """
    Parse a 'Length x Width x Height' string (using the x character or 'x')
    into a (length, width, height) float tuple. Returns (0, 0, 0) on failure.
    """
    try:
        parts = dimensions.replace("x", "x").split("x")
        if len(parts) != 3:
            return (0.0, 0.0, 0.0)
        return tuple(float(p.strip()) for p in parts)  # type: ignore[return-value]
    except Exception:
        return (0.0, 0.0, 0.0)


def _to_float(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


def _to_int(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Main handler
# ---------------------------------------------------------------------------

def handler(event: dict, _context: Any) -> dict:
    logger.info("Event: %s", json.dumps(event))

    if not _authenticate(event):
        return _response(401, {"error": "Unauthorized"})

    http_ctx: dict = (event.get("requestContext") or {}).get("http") or {}
    method: str = http_ctx.get("method", "").upper()
    path: str = http_ctx.get("path", "")

    if path == "/carriers/verify" and method == "GET":
        return _handle_verify_carrier(event)
    if path == "/loads" and method == "GET":
        return _handle_search_loads(event)
    if path == "/metrics" and method == "POST":
        return _handle_save_metrics(event)

    return _response(404, {"error": "Not Found", "path": path, "method": method})


# ---------------------------------------------------------------------------
# Endpoint: GET /carriers/verify
# ---------------------------------------------------------------------------

def _handle_verify_carrier(event: dict) -> dict:
    """
    Query the FMCSA Query Central REST API for a carrier by MC docket number.

    Query parameters
    ----------------
    mc_number : str  (required) - Motor Carrier docket number, digits only.

    Returns
    -------
    200 - Carrier found; includes eligibility flag and key carrier details.
    400 - mc_number missing.
    404 - Carrier not found in the FMCSA database.
    502 - FMCSA API unavailable.
    """
    params: dict = event.get("queryStringParameters") or {}
    mc_number = params.get("mc_number", "").strip()

    if not mc_number:
        return _response(400, {"error": "Query parameter 'mc_number' is required."})

    # Validate: MC numbers are numeric
    if not mc_number.isdigit():
        return _response(
            400, {"error": "mc_number must be a numeric Motor Carrier docket number."}
        )

    try:
        fmcsa_key = _get_secret(FMCSA_SECRET_ARN)
    except Exception:
        logger.exception("Failed to retrieve FMCSA secret")
        return _response(500, {"error": "Internal configuration error."})

    url = (
        "https://mobile.fmcsa.dot.gov/qc/services/carriers/docket-number/"
        f"{mc_number}/?webKey={fmcsa_key}"
    )
    # Log the endpoint shape for troubleshooting, but never log full secrets.
    logger.info(
        "FMCSA request endpoint for MC %s: /qc/services/carriers/docket-number/%s/?webKey=<redacted>",
        mc_number,
        mc_number,
    )

    try:
        req = urllib.request.Request(
            url,
            headers={"Accept": "application/json"},
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw_body = resp.read().decode("utf-8")
            data: Any = json.loads(raw_body)
            logger.info(
                "FMCSA response for MC %s: status=%s payload_type=%s",
                mc_number,
                resp.status,
                type(data).__name__,
            )
    except urllib.error.HTTPError as exc:
        error_body = ""
        try:
            error_body = exc.read().decode("utf-8")
        except Exception:  # noqa: BLE001
            error_body = "<unavailable>"
        if exc.code == 404:
            return _response(
                404,
                {
                    "eligible": False,
                    "mc_number": mc_number,
                    "reason": "Carrier not found in the FMCSA database.",
                },
            )
        logger.error(
            "FMCSA HTTP error %s for MC %s. body_snippet=%s",
            exc.code,
            mc_number,
            error_body[:500],
        )
        return _response(502, {"error": "FMCSA API returned an error.", "fmcsa_status": exc.code})
    except Exception:
        logger.exception("Unexpected error calling FMCSA API for MC %s", mc_number)
        return _response(502, {"error": "FMCSA API unavailable."})

    # FMCSA can return content either as a dict or as a list depending on endpoint/version.
    carrier: dict[str, Any] = {}
    content: Any = data.get("content") if isinstance(data, dict) else data

    if isinstance(content, dict):
        nested = content.get("carrier")
        carrier = nested if isinstance(nested, dict) else content
    elif isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            nested = first.get("carrier")
            carrier = nested if isinstance(nested, dict) else first

    if not carrier:
        return _response(
            404,
            {
                "eligible": False,
                "mc_number": mc_number,
                "reason": "Carrier not found in the FMCSA database.",
            },
        )

    allowed_to_operate: bool = carrier.get("allowedToOperate", "N") == "Y"
    common_auth_status: str = (
        (carrier.get("commonAuthorityStatus") or {}).get("commonAuthorityStatus") or "N"
    )
    # A carrier is eligible when FMCSA marks them allowed to operate
    # and holds at least one active authority grant.
    eligible: bool = allowed_to_operate and common_auth_status in ("A",)

    return _response(
        200,
        {
            "eligible": eligible,
            "mc_number": mc_number,
            "dot_number": carrier.get("dotNumber"),
            "legal_name": carrier.get("legalName"),
            "dba_name": carrier.get("dba"),
            "allowed_to_operate": allowed_to_operate,
            "common_authority_status": (
                (carrier.get("commonAuthorityStatus") or {}).get(
                    "commonAuthorityStatusDesc"
                )
            ),
            "contract_authority_status": (
                (carrier.get("contractAuthorityStatus") or {}).get(
                    "contractAuthorityStatusDesc"
                )
            ),
            "city": carrier.get("phyCity"),
            "state": carrier.get("phyState"),
            "total_power_units": carrier.get("totalPowerUnits"),
            "total_drivers": carrier.get("totalDrivers"),
        },
    )


# ---------------------------------------------------------------------------
# Endpoint: GET /loads
# ---------------------------------------------------------------------------

def _matches_load_filters(load: dict, params: dict) -> bool:
    """Return True when *load* satisfies every active filter in *params*."""

    # ── Exact: load_id ──────────────────────────────────────────────────────
    if "load_id" in params:
        target = _to_int(params["load_id"])
        if target is None or load.get("load_id") != target:
            return False

    # ── String (case-insensitive exact match) ────────────────────────────────
    for field in ("origin", "destination", "equipment_type", "commodity_type"):
        if field in params:
            if (load.get(field) or "").lower() != params[field].lower():
                return False

    # ── Numeric range filters ────────────────────────────────────────────────
    for field in (
        "weight",
        "miles",
        "loadboard_rate",
        "num_of_pieces",
        "pickup_datetime",
        "delivery_datetime",
    ):
        value = load.get(field)
        if value is None:
            continue
        lo = _to_float(params.get(f"{field}_min"))
        hi = _to_float(params.get(f"{field}_max"))
        if lo is not None and value < lo:
            return False
        if hi is not None and value > hi:
            return False

    # ── Dimension range filters ──────────────────────────────────────────────
    length, width, height = _parse_dimensions(load.get("dimensions", "0 x 0 x 0"))
    for dim_name, dim_val in (("length", length), ("width", width), ("height", height)):
        lo = _to_float(params.get(f"{dim_name}_min"))
        hi = _to_float(params.get(f"{dim_name}_max"))
        if lo is not None and dim_val < lo:
            return False
        if hi is not None and dim_val > hi:
            return False

    return True


def _handle_search_loads(event: dict) -> dict:
    """
    Search the available loads catalogue.

    Query parameters (all optional - omitting all returns every load)
    ---------------------------------------------------------------
    load_id              : int    - exact match
    origin               : str    - exact, case-insensitive
    destination          : str    - exact, case-insensitive
    equipment_type       : str    - exact, case-insensitive
    commodity_type       : str    - exact, case-insensitive
    weight_min/max       : float  - pounds
    miles_min/max        : float
    loadboard_rate_min/max : float - USD
    num_of_pieces_min/max : float
    pickup_datetime_min/max  : float - Unix timestamp
    delivery_datetime_min/max : float - Unix timestamp
    length_min/max       : float  - inches (first dimension)
    width_min/max        : float  - inches (second dimension)
    height_min/max       : float  - inches (third dimension)
    """
    params: dict = event.get("queryStringParameters") or {}

    loads: list[dict]
    try:
        loads = _get_loads()
    except Exception:  # noqa: BLE001
        logger.exception("Failed to retrieve loads from S3")
        return _response(500, {"error": "Failed to retrieve loads catalogue."})

    results = [load for load in loads if _matches_load_filters(load, params)]

    return _response(200, {"loads": results, "count": len(results)})


# ---------------------------------------------------------------------------
# Endpoint: POST /metrics
# ---------------------------------------------------------------------------

def _handle_save_metrics(event: dict) -> dict:
    """
    Record call-outcome metrics and publish them to Amazon CloudWatch.

    Request body (JSON)
    -------------------
    sentiment              : float  1.0-5.0  (1 = very negative, 5 = very positive)
    outcome                : str    "successful" | "unsuccessful"
    deal_volume            : float  USD - set to the agreed loadboard_rate
    call_duration_minutes  : float  actual duration of the AI call in minutes
    EmployeeCostSaved is calculated automatically as:
    call_duration_minutes * (EMPLOYEE_COST_PER_HOUR / 60)
    """
    try:
        body: dict = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Request body must be valid JSON."})

    sentiment = body.get("sentiment")
    outcome = body.get("outcome")
    deal_volume = body.get("deal_volume")
    call_duration_minutes = body.get("call_duration_minutes")

    # ── Validation ───────────────────────────────────────────────────────────
    if sentiment is not None:
        try:
            sentiment = float(sentiment)
        except (ValueError, TypeError):
            return _response(400, {"error": "'sentiment' must be a number."})
        if not (1.0 <= sentiment <= 5.0):
            return _response(
                400, {"error": "'sentiment' must be between 1.0 and 5.0."}
            )

    if outcome is not None and outcome not in ("successful", "unsuccessful"):
        return _response(
            400,
            {"error": "'outcome' must be 'successful' or 'unsuccessful'."},
        )

    # ── Build CloudWatch metric data ─────────────────────────────────────────
    now = datetime.now(timezone.utc)
    metric_data: list[dict] = []

    def _add(name: str, value: float, unit: str = "None") -> None:
        metric_data.append(
            {"MetricName": name, "Value": value, "Unit": unit, "Timestamp": now}
        )

    if sentiment is not None:
        _add("CarrierSentiment", sentiment)

    if outcome:
        _add("CarrierCallsTotal", 1, "Count")
        if outcome == "successful":
            _add("SuccessfulDeals", 1, "Count")
        else:
            _add("UnsuccessfulCalls", 1, "Count")

    if deal_volume is not None:
        try:
            _add("DealValue", float(deal_volume))
        except (ValueError, TypeError):
            return _response(400, {"error": "'deal_volume' must be a number."})

    if call_duration_minutes is not None:
        try:
            duration = float(call_duration_minutes)
        except (ValueError, TypeError):
            return _response(
                400, {"error": "'call_duration_minutes' must be a number."}
            )
        _add("CallDurationMinutes", duration)
        # Automated handling saves the full call duration for human staff.
        time_saved = duration
        _add("TimeSavedMinutes", time_saved)
        employee_cost_saved = duration * (EMPLOYEE_COST_PER_HOUR / 60.0)
        _add("EmployeeCostSaved", employee_cost_saved)

    # ── Publish ──────────────────────────────────────────────────────────────
    if metric_data:
        try:
            _cloudwatch.put_metric_data(
                Namespace=CLOUDWATCH_NAMESPACE,
                MetricData=metric_data,
            )
        except Exception:
            logger.exception("Failed to publish metrics to CloudWatch")
            return _response(500, {"error": "Failed to publish metrics."})

    return _response(
        200,
        {
            "message": "Metrics recorded successfully.",
            "metrics_published": len(metric_data),
        },
    )

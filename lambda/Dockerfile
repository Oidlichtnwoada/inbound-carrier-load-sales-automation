# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – dependency installer (no external deps beyond the runtime image,
#            but the stage is retained so future packages need only one edit)
# ─────────────────────────────────────────────────────────────────────────────
FROM public.ecr.aws/lambda/python:3.14 AS builder

WORKDIR /build

# Install only production dependencies from requirements.txt when present.
# boto3 ships pre-installed in the Lambda runtime image; it is re-listed in
# requirements.txt for explicit version pinning and audit-trail purposes.
COPY requirements.txt ./
RUN pip install \
        --no-cache-dir \
        --upgrade \
        --target /build/python \
        -r requirements.txt

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – final image
# ─────────────────────────────────────────────────────────────────────────────
FROM public.ecr.aws/lambda/python:3.14

LABEL maintainer="Inbound Carrier Sales Automation" \
      description="Lambda container image – carrier load sales API" \
      org.opencontainers.image.source="https://github.com/Oidlichtnwoada/inbound-carrier-load-sales-automation"

# Copy site-packages installed in the builder stage
COPY --from=builder /build/python ${LAMBDA_TASK_ROOT}

# Copy application source
COPY app.py ${LAMBDA_TASK_ROOT}/

# Run as a non-root user (UID 1000 is pre-created in the Lambda base image)
# The Lambda runtime itself enforces execution under the sbx_user1051 account,
# so this directive is a defence-in-depth best practice.
USER 1000

# Lambda entry point: module.function
CMD ["app.handler"]

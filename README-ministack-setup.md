# JamunJar local AWS environment — setup and service test guide

This guide covers the MiniStack v1.5.41 development stack in `~/setup` (WSL/Linux) or `C:\Users\pawar\develop\ministack-infra` (PowerShell): **ECS Fargate (3 websites + 7 APIs), ALB, Route 53, RDS PostgreSQL, S3, SQS, and the Nginx gateway**. The application source folders are under `code/`; the Compose project and scripts are in the root directory.

> **Scope:** These are local AWS emulations, not real AWS resources. Commands use placeholder development credentials. Some MiniStack behaviors (notably database persistence, host networking and boot recovery) should be validated against the running image. Do not use production data or credentials.

## 1. Prerequisites and configuration

- Docker Engine or Docker Desktop with the desired WSL distribution enabled.
- Docker Compose v2; `curl` for HTTP testing.
- AWS CLI v2 on youfr WSL/Linux host for the full S3 and SQS smoke tests; optional `psql` (PostgreSQL client) and `jq`.
- A real file at `nginx/local-gateway.conf` (not a directory).
- Ten previously built application images: `web-1:local`, `web-2:local`, `web-3:local`, and `api-1:local` through `api-7:local`.

Build paths in `docker-compose.yml` must point to `./code/web-1`, `./code/web-2`, `./code/web-3`, and `./code/api-1` through `./code/api-7`. Do **not** overwrite your real service Dockerfiles with demo ones.

The example uses the names configured in the checkout’s `.env`. If you choose different names, use the same values in the smoke-test commands. Keep the existing password if RDS has already been provisioned.

```dotenv
RDS_DB_IDENTIFIER=postgres-demo
RDS_DB_NAME=mydb
RDS_MASTER_USERNAME=admin
RDS_MASTER_PASSWORD=CHANGE_ME_TO_A_STRONG_LOCAL_PASSWORD
S3_BUCKETS=s3-uploads-local,s3-documents-local
SQS_QUEUE_NAME=sqs-jobs-local
SQS_DLQ_NAME=sqs-jobs-dlq-local
```

Never commit `.env`. In WSL: `chmod 600 .env`. Do not casually change the RDS master password in `.env` for an already existing DB; editing the file does **not** change the database user's password.

## 2. Startup and general health

Run from the infrastructure root:

```bash
cd ~/setup
sh -n init-ecs.sh
docker compose config --quiet
# Only when image sources have changed, or before first startup:
docker compose --profile build-only build
docker compose up -d
docker compose ps -a
docker compose logs --tail=120 ministack-init
docker compose logs --tail=80 local-gateway
```

The `ministack-init` container is a **one-time job**; status `Exited (0)` is expected. Verify this with:

```bash
docker inspect setup-ministack-init-1 --format '{{.State.ExitCode}}'
```

The command must print `0`. If it is nonzero, check the provisioning log before proceeding. `ministack` should be healthy; `s3-local-gateway` should be running. The ten ECS application containers are started by MiniStack, not as ten standalone Compose services.

To test the AWS API health endpoint:

```bash
curl -fsS http://127.0.0.1:4566/_ministack/health
```

### AWS CLI setup (WSL/Linux)

```bash
export AWS_ACCESS_KEY_ID=000000000000
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export AWS_ENDPOINT_URL=http://127.0.0.1:4566

# Quick API check
aws --endpoint-url="$AWS_ENDPOINT_URL" sts get-caller-identity
```

All `aws` commands below are for the **WSL/Linux host** with AWS CLI installed. If you do not have AWS CLI on the host, use the bundled CLI container for API _inspection_:

```bash
docker compose run --rm --no-deps --entrypoint aws ministack-init \
  --endpoint-url=http://ministack:4566 ecs list-clusters
```

For PowerShell, use `$env:AWS_ACCESS_KEY_ID='000000000000'`, `$env:AWS_SECRET_ACCESS_KEY='test'`, `$env:AWS_DEFAULT_REGION='us-east-1'`, `$env:AWS_ENDPOINT_URL='http://127.0.0.1:4566'`, then `aws --endpoint-url $env:AWS_ENDPOINT_URL ...`. Use `curl.exe`, not the PowerShell alias `curl`.

## 3. ECS Fargate — cluster, services and tasks

```bash
# Cluster
aws --endpoint-url="$AWS_ENDPOINT_URL" ecs list-clusters

# All 10 services
aws --endpoint-url="$AWS_ENDPOINT_URL" ecs list-services --cluster my-cluster

# Requested vs running task counts for every service
aws --endpoint-url="$AWS_ENDPOINT_URL" ecs describe-services \
  --cluster my-cluster \
  --services web-1-svc web-2-svc web-3-svc \
    api-1-svc api-2-svc api-3-svc api-4-svc api-5-svc api-6-svc api-7-svc \
  --query 'services[].{Name:serviceName,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' \
  --output table

# Running task ARNs
aws --endpoint-url="$AWS_ENDPOINT_URL" ecs list-tasks \
  --cluster my-cluster --service-name api-1-svc

# Task definition (includes the API environment variable names)
aws --endpoint-url="$AWS_ENDPOINT_URL" ecs describe-task-definition \
  --task-definition api-1-task \
  --query 'taskDefinition.{Family:family,Revision:revision,Containers:containerDefinitions[].name}'
```

**Pass:** all ten service names exist and eventually show `Desired=1`, `Running=1`, `Pending=0`. A created ECS service is not necessarily a healthy application. Avoid printing a full task definition when you have injected local DB passwords into container environment variables.

To redeploy **only api-1** after rebuilding its image:

```bash
docker compose --profile build-only build api-1
aws --endpoint-url="$AWS_ENDPOINT_URL" ecs update-service \
  --cluster my-cluster --service api-1-svc --force-new-deployment
```

Verify the new container actually uses the rebuilt local image; MiniStack's local-image-cache behavior is emulator-specific.

## 4. ALB and HTTP routing

```bash
# Show ALB and its DNS hostname
aws --endpoint-url="$AWS_ENDPOINT_URL" elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,ARN:LoadBalancerArn}' \
  --output table

# Get ALB and listener ARNs
ALB_ARN=$(aws --endpoint-url="$AWS_ENDPOINT_URL" elbv2 describe-load-balancers \
  --names alb1 --query 'LoadBalancers[0].LoadBalancerArn' --output text)
LISTENER_ARN=$(aws --endpoint-url="$AWS_ENDPOINT_URL" elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" --query 'Listeners[0].ListenerArn' --output text)

# Inspect host/path conditions, priorities and actions
aws --endpoint-url="$AWS_ENDPOINT_URL" elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Conditions:Conditions,Actions:Actions}'

# Target groups
aws --endpoint-url="$AWS_ENDPOINT_URL" elbv2 describe-target-groups \
  --query 'TargetGroups[].{Name:TargetGroupName,Port:Port,Type:TargetType}' \
  --output table
```

### Browser-facing gateway tests (port 80)

The Nginx gateway works around MiniStack v1.5.41's observed custom-hostname-to-ALB routing failure. `--resolve` directs the request to localhost while retaining the requested hostname.

```bash
# web-1 and web-2 should return 200 when running. Demo bodies are "My web 1" and "My web 2".
curl -i --resolve www.jj1.com:80:127.0.0.1 http://www.jj1.com/
curl -i --resolve www.jj2.com:80:127.0.0.1 http://www.jj2.com/

# API 1: expect 200, body "Hello API 1" for demo image
curl -i --resolve api.jj.com:80:127.0.0.1 http://api.jj.com/api-1/

# Apex redirect: expect 301 to www.jj.com
curl -I --resolve jj.com:80:127.0.0.1 http://jj.com/

# Redirect /api-1 on www to api.jj.com (expect 301)
curl -I --resolve www.jj.com:80:127.0.0.1 http://www.jj.com/api-1/
```

ECS configures `web-3` for `www.jj3.com`. Test it directly through the ALB because the gateway and Route 53 configuration currently omit that hostname. The demo image returns `My web 3`.

```bash
curl -i -H 'Host: www.jj3.com' http://127.0.0.1:4566/_alb/alb1/
```

If gateway requests return 502, bypass the gateway and directly exercise MiniStack's ALB:

```bash
curl -i -H 'Host: www.jj1.com' http://127.0.0.1:4566/_alb/alb1/
curl -i -H 'Host: api.jj.com' http://127.0.0.1:4566/_alb/alb1/api-1/

docker logs s3-local-gateway --tail=100
# Check from the Nginx container that it can connect to MiniStack
docker exec s3-local-gateway wget -S -O - \
  --header='Host: www.jj1.com' \
  http://ministack:4566/_alb/alb1/
```

A normal response through the direct ALB test but 502 through the gateway points to the Nginx configuration, DNS resolver or Docker network. A `Route not found` from `awselb/2.0` means the request reached ALB but no rule matched.

## 5. Route 53 — hosted zones and records

```bash
# Expected hosted zones: jj.com., jj1.com., jj2.com.
aws --endpoint-url="$AWS_ENDPOINT_URL" route53 list-hosted-zones \
  --query 'HostedZones[].{Name:Name,Id:Id}' --output table

# Get jj.com hosted-zone ID
ZONE_ID=$(aws --endpoint-url="$AWS_ENDPOINT_URL" route53 list-hosted-zones \
  --query "HostedZones[?Name=='jj.com.'].Id | [0]" --output text)

# Inspect A aliases and other records
aws --endpoint-url="$AWS_ENDPOINT_URL" route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID"
```

**Pass:** apex `jj.com.`, `www.jj.com.`, and `api.jj.com.` have A alias records pointing to the generated `alb1-...elb.amazonaws.com.` name (along with the configured wildcard). Note that MiniStack's Route 53 records **do not configure Windows/WSL DNS automatically**; the Nginx gateway and `curl --resolve` provide local HTTP testing independently of that.

## 6. RDS PostgreSQL — create, connect and query

```bash
# Metadata / advertised endpoint
aws --endpoint-url="$AWS_ENDPOINT_URL" rds describe-db-instances \
  --db-instance-identifier postgres-demo \
  --query 'DBInstances[0].{Identifier:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Endpoint:Endpoint}'

# Discover the PostgreSQL sidecar's host port, if published
# (RDS_BASE_PORT=15432 is the configured starting port, not a guarantee)
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Once the DB reports `available`, discover its **actual** reachable host/port. If `psql` is missing on Ubuntu/WSL: `sudo apt-get update && sudo apt-get install -y postgresql-client`.

```bash
# Replace the port if Docker reports a different PostgreSQL host port.
# This reads .env locally; do NOT print the password or commit the file.
set -a
. ./.env
set +a

PGPASSWORD="$RDS_MASTER_PASSWORD" psql \
  -h 127.0.0.1 -p 15432 \
  -U "$RDS_MASTER_USERNAME" -d "$RDS_DB_NAME" \
  -c 'SELECT current_database(), current_user, version();'
```

Create, read, and remove a test table without touching real application tables:

```bash
PGPASSWORD="$RDS_MASTER_PASSWORD" psql -h 127.0.0.1 -p 15432 \
  -U "$RDS_MASTER_USERNAME" -d "$RDS_DB_NAME" \
  -v ON_ERROR_STOP=1 \
  -c 'CREATE TABLE IF NOT EXISTS ministack_smoke_test (id integer PRIMARY KEY, message text NOT NULL);' \
  -c "INSERT INTO ministack_smoke_test (id, message) VALUES (1, 'postgres works') ON CONFLICT (id) DO UPDATE SET message = EXCLUDED.message;" \
  -c 'SELECT * FROM ministack_smoke_test;' \
  -c 'DROP TABLE ministack_smoke_test;'
```

**Pass:** the query returns row `1 | postgres works`. If you cannot connect from the host, inspect the `rds describe-db-instances` endpoint and the Postgres sidecar's port mapping; don't assume the advertised in-Docker endpoint is host-accessible. Avoid using a production or shared database for destructive smoke tests.

## 7. S3 — buckets, upload, read and delete

```bash
# Expected: s3-uploads-local, s3-documents-local
aws --endpoint-url="$AWS_ENDPOINT_URL" s3api list-buckets \
  --query 'Buckets[].Name' --output table

# Test upload/download in a dedicated smoke-test prefix
printf 'JamunJar MiniStack S3 smoke test\n' > /tmp/s3-smoke.txt
aws --endpoint-url="$AWS_ENDPOINT_URL" s3 cp \
  /tmp/s3-smoke.txt s3://s3-uploads-local/smoke-tests/test.txt

# Verify object metadata
aws --endpoint-url="$AWS_ENDPOINT_URL" s3api head-object \
  --bucket s3-uploads-local --key smoke-tests/test.txt

# Verify content
aws --endpoint-url="$AWS_ENDPOINT_URL" s3 cp \
  s3://s3-uploads-local/smoke-tests/test.txt -

# List prefix
aws --endpoint-url="$AWS_ENDPOINT_URL" s3 ls \
  s3://s3-uploads-local/smoke-tests/

# Cleanup only the test object
aws --endpoint-url="$AWS_ENDPOINT_URL" s3 rm \
  s3://s3-uploads-local/smoke-tests/test.txt
rm -f /tmp/s3-smoke.txt
```

**Pass:** output contains `JamunJar MiniStack S3 smoke test`. Use a dedicated test prefix; avoid deleting the entire bucket.

## 8. SQS — send, receive, delete and inspect DLQ

```bash
# Expected: sqs-jobs-local and sqs-jobs-dlq-local
aws --endpoint-url="$AWS_ENDPOINT_URL" sqs list-queues

# Resolve the work queue URL
QUEUE_URL=$(aws --endpoint-url="$AWS_ENDPOINT_URL" sqs get-queue-url \
  --queue-name sqs-jobs-local --query QueueUrl --output text)
echo "$QUEUE_URL"

# Verify its settings and dead-letter policy
aws --endpoint-url="$AWS_ENDPOINT_URL" sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" --attribute-names All

# Send a test message
aws --endpoint-url="$AWS_ENDPOINT_URL" sqs send-message \
  --queue-url "$QUEUE_URL" \
  --message-body '{"type":"smoke-test","source":"readme"}'

# Receive the message (requires jq for safe deletion below)
RECEIVED=$(aws --endpoint-url="$AWS_ENDPOINT_URL" sqs receive-message \
  --queue-url "$QUEUE_URL" --max-number-of-messages 1 \
  --wait-time-seconds 10 --visibility-timeout 30 --output json)
printf '%s\n' "$RECEIVED" | jq .

# Delete exactly the received message so it is not processed again
RECEIPT=$(printf '%s' "$RECEIVED" | jq -r '.Messages[0].ReceiptHandle // empty')
if [ -n "$RECEIPT" ]; then
  aws --endpoint-url="$AWS_ENDPOINT_URL" sqs delete-message \
    --queue-url "$QUEUE_URL" --receipt-handle "$RECEIPT"
else
  echo 'No message returned; check whether another consumer received it.'
fi

# Inspect DLQ (do not consume production-like messages unless intentional)
DLQ_URL=$(aws --endpoint-url="$AWS_ENDPOINT_URL" sqs get-queue-url \
  --queue-name sqs-jobs-dlq-local --query QueueUrl --output text)
aws --endpoint-url="$AWS_ENDPOINT_URL" sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

**Pass:** `send-message` returns a `MessageId`, `receive-message` returns a message with the test body, and `delete-message` succeeds. If other applications are consuming `sqs-jobs-local`, they may receive the message first. For deterministic isolated tests, use a temporary dedicated queue.

The work queue is configured for a 30-second visibility timeout, 10-second long polling, and a DLQ after five failed receives. A DLQ test should be done only against a separate test queue because retries and timeouts can interfere with running workers.

## 9. Persistence / reboot checks

Persistence is configured by `PERSIST_STATE=1`, `S3_PERSIST=1`, `RDS_PERSIST=1` and Docker volumes. This is **not** a backup and does not guarantee SQS durability after an abrupt shutdown.

1. Create an S3 object, one harmless PostgreSQL row and an SQS test message (use dedicated test resources).
2. Stop cleanly: `docker compose stop`, not `docker compose down -v`.
3. Restart via `docker compose up -d`, and rerun the initializer if needed: `docker compose up --no-deps --force-recreate ministack-init`.
4. Confirm the DB row and S3 object remain, then test whether the SQS message remained. Clean up the test data.
5. After an actual machine reboot, confirm Docker Desktop or Docker Engine starts and your systemd/Windows scheduled startup mechanism reruns provisioning when needed. `restart: unless-stopped` does **not** itself re-execute the completed one-shot initializer.

> On Windows + Docker Desktop + WSL2, Windows startup is not the same as a WSL distribution boot. Ensure your chosen startup mechanism starts Docker and the Compose project. Do not simultaneously launch two independent Compose projects bound to ports 80/4566.

## 10. Troubleshooting quick reference

| Symptom                               | Check                                    | Likely interpretation                                                      |
| ------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------- |
| Nginx mount error (`not a directory`) | `ls -ld nginx/local-gateway.conf`        | File missing, or Docker created a directory at the mount source            |
| HTTP 502                              | `docker logs s3-local-gateway`           | Gateway cannot reach/resolve `ministack:4566`; check `resolver 127.0.0.11` |
| S3 XML at `www.jj1.com`               | Confirm Nginx owns host port 80          | Request bypassed gateway and fell into MiniStack S3 fallback               |
| `Route not found` from `awselb/2.0`   | Inspect ALB listener rules               | ALB reached but host/path rule did not match                               |
| ECS service exists but app fails      | `ecs describe-services`, task events     | Task not running, image cache or target problems                           |
| RDS port refused                      | `rds describe-db-instances`, `docker ps` | DB not ready or wrong host/port                                            |
| S3 bucket missing                     | `s3api list-buckets`, initializer logs   | Bucket provisioner failed or state was reset                               |
| SQS queue missing                     | `sqs list-queues`, initializer logs      | Queue provisioner failed or state was reset                                |
| Port 80 in use                        | `docker ps`, `ss -ltnp` / `netstat`      | Another service or another Compose project occupies port 80                |

To see detailed initialization errors:

```bash
docker compose logs --tail=200 ministack-init
docker logs ministack --tail=200
docker logs s3-local-gateway --tail=100
```

## 11. Expected service checklist

| Service          | Expected validation                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------------- |
| MiniStack        | Health endpoint responds                                                                                   |
| ECS              | 1 cluster, 10 services, desired/running counts match                                                       |
| ALB              | `alb1` listener and routing rules exist                                                                    |
| Websites         | `www.jj1.com/` and `www.jj2.com/` respond through Nginx. `www.jj3.com/` responds through the ALB directly. |
| APIs             | `api.jj.com/api-1/` responds correctly                                                                     |
| Route 53         | Three zones with ALB A aliases                                                                             |
| RDS PostgreSQL   | DB available; SQL create/read/delete succeeds                                                              |
| S3               | Both buckets exist; object upload/download/delete succeeds                                                 |
| SQS              | Work queue and DLQ exist; send/receive/delete succeeds                                                     |
| Boot/persistence | Restart restores services and retained test data as supported                                              |

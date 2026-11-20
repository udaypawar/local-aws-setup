
#!/bin/sh
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://ministack:4566}"
CLUSTER="my-cluster"
ALB_NAME="alb1"

aws_local() {
  aws --endpoint-url="$ENDPOINT" "$@"
}

valid() {
  [ -n "${1:-}" ] &&
  [ "$1" != "None" ] &&
  [ "$1" != "null" ]
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# ============================================================
# 1. NETWORK
# ============================================================

VPC_ID=$(aws_local ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

valid "$VPC_ID" || fail "No default VPC"

SUBNETS=$(aws_local ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' --output text)

set -- $SUBNETS

[ "$#" -ge 2 ] || fail "Expected at least 2 subnets"

SUBNET_1="$1"
SUBNET_2="$2"

SG_ID=$(aws_local ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)

valid "$SG_ID" || fail "No security group"

echo "Network: $VPC_ID / $SUBNET_1 $SUBNET_2 / $SG_ID"

# ============================================================
# 2. APPLICATION LOAD BALANCER
# ============================================================

ALB_ARN=$(aws_local elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName=='$ALB_NAME'].LoadBalancerArn | [0]" \
  --output text)

if ! valid "$ALB_ARN"; then
  ALB_ARN=$(aws_local elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$SUBNET_1" "$SUBNET_2" \
    --security-groups "$SG_ID" \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)
fi

valid "$ALB_ARN" || fail "Unable to find or create ALB"

ALB_DNS=$(aws_local elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

ALB_ZONE_ID=$(aws_local elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' \
  --output text)

valid "$ALB_DNS" || fail "ALB DNS name missing"
valid "$ALB_ZONE_ID" || fail "ALB zone ID missing"

echo "ALB: $ALB_NAME ($ALB_DNS)"

# ============================================================
# 3. ECS CLUSTER
# ============================================================

CLUSTER_EXISTS=$(aws_local ecs list-clusters \
  --query "clusterArns[?contains(@, ':cluster/$CLUSTER')] | [0]" \
  --output text)

if ! valid "$CLUSTER_EXISTS"; then
  aws_local ecs create-cluster \
    --cluster-name "$CLUSTER" >/dev/null
fi

# ============================================================
# 4. ROUTE 53
# ============================================================

for DOMAIN in jj.com jj1.com jj2.com; do

  ZONE_ID=$(aws_local route53 list-hosted-zones \
    --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" \
    --output text)

  if ! valid "$ZONE_ID"; then
    ZONE_ID=$(aws_local route53 create-hosted-zone \
      --name "$DOMAIN." \
      --caller-reference "ministack-$DOMAIN" \
      --query 'HostedZone.Id' \
      --output text)
  fi

  valid "$ZONE_ID" || fail "Hosted zone missing: $DOMAIN"

  case "$DOMAIN" in
    jj.com)
      RECORDS="jj.com. www.jj.com. api.jj.com. *.jj.com."
      ;;
    *)
      RECORDS="$DOMAIN. www.$DOMAIN. *.$DOMAIN."
      ;;
  esac

  for RECORD in $RECORDS; do

    BATCH=$(printf \
      '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","AliasTarget":{"HostedZoneId":"%s","DNSName":"%s.","EvaluateTargetHealth":false}}}]}' \
      "$RECORD" "$ALB_ZONE_ID" "$ALB_DNS")

    aws_local route53 change-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --change-batch "$BATCH" >/dev/null

  done

  echo "Route 53: $DOMAIN -> $ALB_DNS"
done

# ============================================================
# 5. S3 BUCKETS
# ============================================================

S3_BUCKETS="${S3_BUCKETS:-s3-uploads-local,s3-documents-local}"

OLD_S3_IFS="$IFS"
IFS=','

for BUCKET in $S3_BUCKETS; do
  IFS="$OLD_S3_IFS"

  [ -n "$BUCKET" ] || fail "Empty S3 bucket name"

  if aws_local s3api head-bucket \
    --bucket "$BUCKET" >/dev/null 2>&1; then

    echo "S3 bucket exists: $BUCKET"

  else
    echo "Creating S3 bucket: $BUCKET"

    aws_local s3api create-bucket \
      --bucket "$BUCKET" >/dev/null
  fi

  IFS=','
done

IFS="$OLD_S3_IFS"

# ============================================================
# 6. SQS QUEUES + DEAD LETTER QUEUE
# ============================================================

SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-jj-jobs-local}"
SQS_DLQ_NAME="${SQS_DLQ_NAME:-jj-jobs-dlq-local}"

[ "$SQS_QUEUE_NAME" != "$SQS_DLQ_NAME" ] ||
  fail "Queue and DLQ must have different names"

case "$SQS_QUEUE_NAME:$SQS_DLQ_NAME" in
  *.fifo*)
    fail "FIFO queues are not supported by this provisioner"
    ;;
esac

# Create or reuse DLQ

DLQ_URL=$(aws_local sqs get-queue-url \
  --queue-name "$SQS_DLQ_NAME" \
  --query QueueUrl \
  --output text 2>/dev/null || true)

if ! valid "$DLQ_URL"; then

  DLQ_URL=$(aws_local sqs create-queue \
    --queue-name "$SQS_DLQ_NAME" \
    --attributes '{"MessageRetentionPeriod":"1209600"}' \
    --query QueueUrl \
    --output text)

  echo "Created SQS DLQ: $SQS_DLQ_NAME"

else
  echo "SQS DLQ exists: $SQS_DLQ_NAME"
fi

DLQ_ARN=$(aws_local sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text)

valid "$DLQ_ARN" || fail "No DLQ ARN"

# Create or reuse work queue

QUEUE_URL=$(aws_local sqs get-queue-url \
  --queue-name "$SQS_QUEUE_NAME" \
  --query QueueUrl \
  --output text 2>/dev/null || true)

if ! valid "$QUEUE_URL"; then

  QUEUE_URL=$(aws_local sqs create-queue \
    --queue-name "$SQS_QUEUE_NAME" \
    --query QueueUrl \
    --output text)

  echo "Created SQS queue: $SQS_QUEUE_NAME"

else
  echo "SQS queue exists: $SQS_QUEUE_NAME"
fi

REDRIVE_POLICY=$(printf \
  '{"deadLetterTargetArn":"%s","maxReceiveCount":"5"}' \
  "$DLQ_ARN")

QUEUE_ATTRIBUTES=$(printf \
  '{"VisibilityTimeout":"30","ReceiveMessageWaitTimeSeconds":"10","RedrivePolicy":"%s"}' \
  "$(printf '%s' "$REDRIVE_POLICY" | sed 's/"/\\"/g')")

aws_local sqs set-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attributes "$QUEUE_ATTRIBUTES"

echo "SQS: $SQS_QUEUE_NAME -> $SQS_DLQ_NAME"

# ============================================================
# 7. RDS POSTGRESQL
# ============================================================

RDS_ID="${RDS_DB_IDENTIFIER:-jj-postgres}"
DB_NAME="${RDS_DB_NAME:-jamunjar}"
DB_USER="${RDS_MASTER_USERNAME:-jamunjar}"
DB_PASSWORD="${RDS_MASTER_PASSWORD:?RDS_MASTER_PASSWORD is required}"

DB_STATUS=$(aws_local rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || true)

if ! valid "$DB_STATUS"; then

  echo "Creating PostgreSQL RDS: $RDS_ID"

  aws_local rds create-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --allocated-storage 20 \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" >/dev/null

else
  echo "Reusing PostgreSQL RDS: $RDS_ID ($DB_STATUS)"
fi

# Wait until RDS endpoint is available

DB_HOST=""
DB_PORT=""

I=0

while [ "$I" -lt 90 ]; do

  DB_HOST=$(aws_local rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text 2>/dev/null || true)

  DB_PORT=$(aws_local rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].Endpoint.Port' \
    --output text 2>/dev/null || true)

  if valid "$DB_HOST" && valid "$DB_PORT"; then
    break
  fi

  I=$((I + 1))
  sleep 2
done

valid "$DB_HOST" || fail "RDS endpoint unavailable"
valid "$DB_PORT" || fail "RDS port unavailable"

echo "RDS endpoint: $DB_HOST:$DB_PORT / $DB_NAME"

# Prepare JSON-safe task environment values

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

DB_PASSWORD_JSON=$(json_escape "$DB_PASSWORD")
DB_HOST_JSON=$(json_escape "$DB_HOST")
DB_USER_JSON=$(json_escape "$DB_USER")
DB_NAME_JSON=$(json_escape "$DB_NAME")

# ============================================================
# 8. TARGET GROUP HELPER
# ============================================================

get_tg() {

  TG_NAME="$1"

  TG=$(aws_local elbv2 describe-target-groups \
    --query "TargetGroups[?TargetGroupName=='$TG_NAME'].TargetGroupArn | [0]" \
    --output text)

  if ! valid "$TG"; then

    TG=$(aws_local elbv2 create-target-group \
      --name "$TG_NAME" \
      --protocol HTTP \
      --port 80 \
      --vpc-id "$VPC_ID" \
      --target-type ip \
      --query 'TargetGroups[0].TargetGroupArn' \
      --output text)
  fi

  valid "$TG" || fail "Cannot create target group: $TG_NAME"

  printf '%s' "$TG"
}

# ============================================================
# 9. ALB LISTENER
# ============================================================

DEFAULT_TG=$(get_tg default-tg)

LISTENER_ARN=$(aws_local elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text)

if ! valid "$LISTENER_ARN"; then

  LISTENER_ARN=$(aws_local elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$DEFAULT_TG" \
    --query 'Listeners[0].ListenerArn' \
    --output text)
fi

valid "$LISTENER_ARN" || fail "ALB listener unavailable"

has_priority() {

  PRIORITY="$1"

  RULE=$(aws_local elbv2 describe-rules \
    --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Priority=='$PRIORITY'].RuleArn | [0]" \
    --output text)

  valid "$RULE"
}

# Apex domain redirect

if ! has_priority 5; then

  aws_local elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 5 \
    --conditions '[{"Field":"host-header","Values":["jj.com"]}]' \
    --actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTP","Port":"80","Host":"www.jj.com","Path":"/#{path}","Query":"#{query}","StatusCode":"HTTP_301"}}]' >/dev/null
fi

# Website API paths redirect to API hostname

if ! has_priority 8; then

  aws_local elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority 8 \
    --conditions '[{"Field":"host-header","Values":["www.jj.com"]},{"Field":"path-pattern","Values":["/api-*"]}]' \
    --actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTP","Port":"80","Host":"api.jj.com","Path":"/#{path}","Query":"#{query}","StatusCode":"HTTP_301"}}]' >/dev/null
fi

# ============================================================
# 10. ECS SERVICE MATRIX
# ============================================================

SERVICES='
web-1|web-1:local|www.jj1.com|/|10
web-2|web-2:local|www.jj2.com|/|20
web-3|web-3:local|www.jj3.com|/|30
api-1|api-1:local|api.jj.com|/api-1|40
api-2|api-2:local|api.jj.com|/api-2|50
api-3|api-3:local|api.jj.com|/api-3|60
api-4|api-4:local|api.jj.com|/api-4|70
api-5|api-5:local|api.jj.com|/api-5|80
api-6|api-6:local|api.jj.com|/api-6|90
api-7|api-7:local|api.jj.com|/api-7|100
'

OLD_IFS="$IFS"

IFS='
'

for ENTRY in $SERVICES; do

  [ -n "$ENTRY" ] || continue

  IFS='|'
  set -- $ENTRY

  IFS='
'

  NAME="$1"
  IMAGE="$2"
  HOST="$3"
  PREFIX="$4"
  PRIORITY="$5"

  TG_ARN=$(get_tg "${NAME}-tg")

  if [ "$PREFIX" = "/" ]; then
    PATTERNS='["/*"]'
  else
    PATTERNS="[\"$PREFIX\",\"$PREFIX/*\"]"
  fi

  if ! has_priority "$PRIORITY"; then

    CONDITIONS=$(printf \
      '[{"Field":"host-header","Values":["%s"]},{"Field":"path-pattern","Values":%s}]' \
      "$HOST" "$PATTERNS")

    aws_local elbv2 create-rule \
      --listener-arn "$LISTENER_ARN" \
      --priority "$PRIORITY" \
      --conditions "$CONDITIONS" \
      --actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
  fi

  # Provide AWS and database configuration to API tasks

  case "$NAME" in

    api-*)

      DB_ENV=$(printf ',"environment":[{"name":"DB_HOST","value":"%s"},{"name":"DB_PORT","value":"%s"},{"name":"DB_NAME","value":"%s"},{"name":"DB_USER","value":"%s"},{"name":"DB_PASSWORD","value":"%s"},{"name":"AWS_ENDPOINT_URL","value":"http://ministack:4566"},{"name":"AWS_DEFAULT_REGION","value":"us-east-1"},{"name":"AWS_ACCESS_KEY_ID","value":"000000000000"},{"name":"AWS_SECRET_ACCESS_KEY","value":"test"},{"name":"S3_BUCKETS","value":"%s"},{"name":"SQS_QUEUE_NAME","value":"%s"},{"name":"SQS_DLQ_NAME","value":"%s"}]' \
        "$DB_HOST_JSON" \
        "$DB_PORT" \
        "$DB_NAME_JSON" \
        "$DB_USER_JSON" \
        "$DB_PASSWORD_JSON" \
        "$(json_escape "$S3_BUCKETS")" \
        "$(json_escape "$SQS_QUEUE_NAME")" \
        "$(json_escape "$SQS_DLQ_NAME")")
      ;;

    *)
      DB_ENV=''
      ;;
  esac

  DEFINITIONS=$(printf \
    '[{"name":"%s","image":"%s","essential":true,"portMappings":[{"containerPort":80,"protocol":"tcp"}]%s}]' \
    "$NAME" "$IMAGE" "$DB_ENV")

  # Register task definition

  TASK_ARN=$(aws_local ecs register-task-definition \
    --family "${NAME}-task" \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 \
    --memory 512 \
    --container-definitions "$DEFINITIONS" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

  valid "$TASK_ARN" || fail "Task definition failed: $NAME"

  # Create or update ECS service

  SERVICE_ARN=$(aws_local ecs list-services \
    --cluster "$CLUSTER" \
    --query "serviceArns[?contains(@, '/$NAME-svc')] | [0]" \
    --output text)

  if valid "$SERVICE_ARN"; then

    aws_local ecs update-service \
      --cluster "$CLUSTER" \
      --service "${NAME}-svc" \
      --task-definition "$TASK_ARN" \
      --force-new-deployment >/dev/null

    echo "Updated ECS service: $NAME"

  else

    aws_local ecs create-service \
      --cluster "$CLUSTER" \
      --service-name "${NAME}-svc" \
      --task-definition "${NAME}-task" \
      --desired-count 1 \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SG_ID]}" \
      --load-balancers "targetGroupArn=$TG_ARN,containerName=$NAME,containerPort=80" >/dev/null

    echo "Created ECS service: $NAME"

  fi

done

IFS="$OLD_IFS"

echo "=============================================="
echo "MiniStack provisioning completed."
echo "ECS: 3 websites + 7 APIs"
echo "RDS: PostgreSQL"
echo "S3: $S3_BUCKETS"
echo "SQS: $SQS_QUEUE_NAME / $SQS_DLQ_NAME"
echo "=============================================="

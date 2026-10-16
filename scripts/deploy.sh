#!/usr/bin/env bash
# Deploys image tag $1 on the EC2 host. Run as root from the repo checkout (/opt/todo-app).
#   CI:        invoked through SSM Run Command after `git checkout <sha>`
#   Rollback:  sudo /opt/todo-app/scripts/deploy.sh <previous-sha>
# Secrets come from SSM Parameter Store via the instance IAM role; nothing is stored in git.
set -euo pipefail

TAG="${1:?usage: deploy.sh <image-tag>}"
SSM_PREFIX="${SSM_PREFIX:-/todo-app}"
cd "$(dirname "$0")/.."

imds_token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_DEFAULT_REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/placement/region)
export AWS_DEFAULT_REGION

echo "==> Rendering .env from SSM ${SSM_PREFIX}"
umask 077
aws ssm get-parameters-by-path --path "$SSM_PREFIX" --recursive --with-decryption \
    --query 'Parameters[*].[Name,Value]' --output text \
  | while IFS=$'\t' read -r name value; do printf "%s='%s'\n" "${name##*/}" "$value"; done > .env.new
grep -q '^SPRING_DATASOURCE_URL=' .env.new || { echo "SSM parameters missing under ${SSM_PREFIX}"; exit 1; }
# Alert delivery is optional, but compose requires the secret's variable to be defined
grep -q '^ALERT_SLACK_WEBHOOK_URL=' .env.new || echo "ALERT_SLACK_WEBHOOK_URL=" >> .env.new
echo "IMAGE_TAG=${TAG}" >> .env.new

PREV_TAG=$(cat .deployed_tag 2>/dev/null || true)
mv .env.new .env

wait_healthy() {
  for _ in $(seq 1 36); do   # up to ~3 minutes
    status=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q backend)" 2>/dev/null || echo missing)
    if [ "$status" = healthy ] && curl -fsS -o /dev/null "http://localhost:${APP_PORT:-80}/api/todos"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

echo "==> Deploying ${TAG} (previous: ${PREV_TAG:-none})"
docker compose pull --quiet backend frontend   # fails fast if the tag was never pushed
docker compose up -d --no-build --remove-orphans
# Prometheus/Alertmanager re-read their (bind-mounted) config on SIGHUP
docker compose kill -s SIGHUP prometheus alertmanager >/dev/null 2>&1 || true

if wait_healthy; then
  echo "$TAG" > .deployed_tag
  docker image prune -af --filter "until=168h" >/dev/null   # keep a week of images for fast rollback
  echo "==> ${TAG} is healthy"
  exit 0
fi

echo "!! ${TAG} failed its health check"
docker compose logs --tail 80 backend || true
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TAG" ]; then
  echo "==> Auto-rolling back to ${PREV_TAG}"
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${PREV_TAG}/" .env
  docker compose up -d --no-build
  wait_healthy && echo "==> Rolled back to ${PREV_TAG}" || echo "!! Rollback is unhealthy too - check RDS / host"
fi
exit 1

# Failure and rollback scenarios

Two facts about this setup shape every answer below.

- **Images are immutable and tagged with the git SHA.** Every commit on `main` that passed CI has its own image in Docker Hub, `<user>/todo-backend:<sha>`. "Rolling back" means running an older tag. Nothing gets rebuilt.
- **One script deploys everything.** [`scripts/deploy.sh <tag>`](scripts/deploy.sh) is what CI runs over SSM, and it is also what a human runs by hand. It renders `.env` from SSM, pulls the images, restarts the stack and waits for health. If the new version doesn't become healthy, it **automatically rolls back** to the last healthy tag (stored in `/opt/todo-app/.deployed_tag`).

---

## 1. A faulty version is deployed. How do you roll back?

**Faulty and unhealthy** (fails health checks or crashes on start): no action needed. `deploy.sh` waits up to about 3 minutes for the backend container to report `healthy` *and* for `GET /api/todos` through nginx to return 2xx. If either check fails, it restarts the previous tag and exits non-zero. The GitHub Actions run goes red, so the team sees it.

**Faulty but healthy** (a logic bug that health checks can't see). Roll back by choosing an earlier tag:

| Option | How | When |
|---|---|---|
| **A. Revert in git (preferred)** | `git revert <bad-sha> && git push` | Normal case. The pipeline tests, builds and deploys the fix. History stays truthful and `main` is never "ahead" of production. About 5 minutes. |
| **B. Redeploy a known-good SHA** | GitHub → Actions → the last good run on `main` → **Re-run all jobs**. Its image already exists, so this is fast. | Urgent and CI is available. About 2 minutes. |
| **C. On the host** | `aws ssm start-session --target <id>`, then `cd /opt/todo-app && sudo git checkout <good-sha> && sudo bash scripts/deploy.sh <good-sha>` | CI is down (see #3). About 1 minute. |

To find good SHAs, look at the green runs in Actions, or the tags in Docker Hub. Images stay on the host for 7 days (`docker image prune --filter until=168h`), so a recent rollback doesn't even need a pull.

**Database caveat.** The schema is managed by `ddl-auto=update`, which only *adds* columns and tables. An older version can run against a newer schema, so rolling back the app never requires rolling back the DB. If destructive migrations were introduced (Flyway or Liquibase), the rule would be expand/contract: never drop in the same release that stops using a column.

## 2. The application crashes after deployment. What happens?

Layer by layer:

1. **Container level.** `restart: unless-stopped` makes Docker restart a crashed process immediately. The JVM runs with `-XX:+ExitOnOutOfMemoryError`, so an OOM kills the process cleanly and it restarts, instead of limping along.
2. **Deploy level.** If the crash happens during the deployment window, the health gate in `deploy.sh` fails. It auto-rolls back to the previous tag and the pipeline fails (see #1).
3. **Later crashes, after a successful deploy:**
   - `ContainerRestarting` (more than 2 restarts in 15 min) and `BackendDown` (scrape failing for 2 min) fire to Slack through Alertmanager.
   - The Grafana *Container restarts & uptime* table shows which container is flapping.
   - nginx keeps serving the static frontend. API calls return 502 until the backend is back, and the UI shows "Error fetching todos".
4. **Diagnosis:** `docker compose ps`, `docker compose logs --tail 200 backend`, and `docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}}' <container>`. Common causes: bad or missing env/SSM value (startup fails fast and the log names the property), RDS unreachable (see #6), out of memory (raise `mem_limit` or the instance size).
5. **Fix:** roll back (#1), or fix forward with a new commit.

## 3. The CI/CD tool is unavailable. Can you still deploy?

Yes. The pipeline is a convenience, not a dependency. Every step it performs can be done by hand with the same artifacts and the same script.

- **Deploy an image that's already built** (the common case, e.g. a rollback). Use option C from #1. It needs only AWS console or CLI access. SSM Session Manager works without SSH or an open port 22.
- **Deploy new code while GitHub Actions is down.** On a trusted workstation:
  ```bash
  SHA=$(git rev-parse HEAD)
  (cd Backend/todo-summary-assistant && mvn -B verify)          # don't skip the tests
  docker build -t $USER_NS/todo-backend:$SHA  Backend/todo-summary-assistant
  docker build -t $USER_NS/todo-frontend:$SHA Frontend/todo
  docker push $USER_NS/todo-backend:$SHA && docker push $USER_NS/todo-frontend:$SHA
  git push origin HEAD          # the host checks out this SHA, so it must be on the remote
  # then option C from #1 with $SHA
  ```
- **If Docker Hub is down too:** build on the EC2 host itself with `docker compose build && IMAGE_TAG=$SHA docker compose up -d`. It's slower, but the Dockerfiles are self-contained.
- **Afterwards:** record what was deployed manually. When CI is back, re-run the pipeline on that SHA so the audit trail and image tags are consistent again.

## 4. Secrets are leaked. What steps do you take?

Treat it as an incident. The order matters: **contain, then rotate, then clean up, then learn.**

1. **Contain (minutes).** Work out which secret leaked and where: a git commit, CI logs, a screenshot, Slack. Make the location private or delete it. For a public repo, assume bots already scraped it; GitHub secret scanning reports within seconds.
2. **Rotate.** This is the actual fix, because deleting a leak never "un-leaks" it.

   | Secret | Rotation |
   |---|---|
   | RDS password | `aws rds modify-db-instance --db-instance-identifier todo-app-db --master-user-password '<new>' --apply-immediately`, then `aws ssm put-parameter --overwrite ... /todo-app/SPRING_DATASOURCE_PASSWORD`, then redeploy the current SHA |
   | Cohere API key | Revoke it in the Cohere dashboard, create a new one, update `/todo-app/COHERE_API_KEY`, redeploy |
   | Slack webhook | Delete it in the Slack app config and create a new one, update `/todo-app/SLACK_WEBHOOK_URL` / `ALERT_SLACK_WEBHOOK_URL`, redeploy. For the alert webhook also run `docker compose up -d --force-recreate alertmanager`, because Compose doesn't recreate a container when only a secret's value changes. |
   | Docker Hub token | Revoke it in Docker Hub, create a new one, update the GitHub secret `DOCKERHUB_TOKEN`. Check Docker Hub for images pushed by anyone else. |
   | Grafana admin password | `grafana cli admin reset-admin-password`, update the SSM parameter |
   | AWS credentials | The design keeps none to leak: the instance role and GitHub OIDC both issue temporary credentials. If a human's IAM key leaks: deactivate it, delete it, and review CloudTrail. |

3. **Assess blast radius.** Check CloudTrail for API calls by the affected principal, the RDS logs and the `todo_db` data for unexpected access, and the Cohere/Slack usage dashboards. Because RDS is not publicly accessible, a leaked DB password alone doesn't expose data; an attacker would also need a foothold in the EC2 security group.
4. **Clean up git history** if the secret was committed. Use `git filter-repo` to remove it and force-push, and ask collaborators to re-clone. This only reduces exposure; rotation in step 2 is what actually removes the risk.
5. **Prevent recurrence.** Turn on GitHub secret scanning and push protection. Add a pre-commit hook (gitleaks). Keep `.env` in `.gitignore` (already done). Write a short post-mortem.

## 5. The EC2 instance fails. How do you recover?

The instance is **cattle, not a pet**. All state lives elsewhere: data in RDS, config in SSM and git, images in Docker Hub. The only local state is Prometheus and Grafana history, which is acceptable to lose.

| Failure | Recovery |
|---|---|
| Underlying hardware fails | Add a CloudWatch alarm on `StatusCheckFailed_System` with the **EC2 recover** action. It migrates the instance to new hardware and keeps its ID, IP and EBS. |
| Instance is unhealthy or OS is broken | Reboot. If that doesn't help, stop and start, which also moves it to a new host. Containers restart on their own (`restart: unless-stopped`, docker service enabled). |
| Instance is gone or unrecoverable | `terraform apply -replace=aws_instance.app`. User data reinstalls Docker and clones the repo, and the Elastic IP moves to the new instance. Update the `EC2_INSTANCE_ID` variable in GitHub and re-run the last green pipeline. Total about 10 minutes. |
| AZ outage | Same as above in another subnet or AZ. RDS Multi-AZ, if enabled, has already failed over. |

The data is safe throughout, because RDS is a separate managed service. **RTO** is about 10–15 minutes for a full rebuild. **RPO** is 0 for app data.

**Hardening path** (if the downtime isn't acceptable): put the instance in an Auto Scaling group (min=max=1) behind an ALB with a health check, so replacement is automatic. Then run 2+ instances for zero-downtime deploys, or move to ECS Fargate.

## 6. The RDS database becomes unavailable. What is the impact and the recovery plan?

**Impact**

- **What breaks:** every `/api/todos*` call returns 5xx after HikariCP's connection timeout (30 s by default), so the UI cannot list, create, update or delete todos. Summaries fail too, because they read pending todos first.
- **What keeps working:** the frontend still loads (served by nginx), and Grafana keeps showing the problem.
- **Container behaviour:** the backend container is marked `unhealthy`, because `/actuator/health` includes the DB check. It stays running, and reconnects by itself when the DB returns, with no restart needed. A deploy during the outage would fail its health gate and roll back, which is the correct behaviour.
- **How we find out:** `HighErrorRate` fires (5xx > 5%). The Grafana *DB connection pool* panel shows pending connections climbing and active connections dropping.

**Recovery plan, by cause**

| Cause | Recovery | Data loss |
|---|---|---|
| AZ / instance failure, **Multi-AZ on** (`db_multi_az = true`) | Automatic failover to the standby in the other AZ in about 60–120 s. The endpoint DNS stays the same, so the app reconnects on its own. | None (synchronous replication) |
| Same failure, single-AZ (free-tier default) | AWS replaces the host and recovers from storage, typically in minutes. If that isn't possible, use point-in-time restore. | None to seconds |
| Bad data or accidental delete/drop | **Point-in-time restore** to just before the incident: `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier todo-app-db --target-db-instance-identifier todo-app-db-restored --restore-time <UTC>`. Then point `/todo-app/SPRING_DATASOURCE_URL` at the new endpoint and redeploy the current SHA. | Up to about 5 minutes (transaction log upload interval) |
| Instance deleted | Restore from the automatic final snapshot (`todo-app-db-final`) or the latest automated or manual snapshot, then repoint SSM as above. | Since the last snapshot |
| Storage full | Raise `allocated_storage`, or enable storage autoscaling (`max_allocated_storage`). No downtime. | None |
| Credentials rotated or wrong | Health checks fail on deploy and the auto-rollback keeps the old version running. Fix the SSM value and redeploy. | None |

**Backups**

- **Automated backups:** daily snapshot plus transaction logs, which enables point-in-time restore. Retention is a Terraform variable. Use **7–35 days in production**. Free-plan accounts may be capped at 1.
- **Manual snapshot before risky changes:** `aws rds create-db-snapshot --db-instance-identifier todo-app-db --db-snapshot-identifier pre-<change>`. Manual snapshots don't expire.
- **Restores are rehearsed, not assumed.** Once a quarter, restore a snapshot to a scratch instance and run the app against it.
- **Production settings to switch on:** Multi-AZ, `deletion_protection = true`, backup retention ≥ 7 days, storage autoscaling, and a CloudWatch alarm on `FreeStorageSpace` and `DatabaseConnections`.

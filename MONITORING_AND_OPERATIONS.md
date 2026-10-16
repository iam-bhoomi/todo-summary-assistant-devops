# Monitoring and operations

**The stack, all on the EC2 host in [docker-compose.yml](docker-compose.yml):**

- **Prometheus** scrapes three sources:
  - the Spring Boot backend at `/actuator/prometheus` (Micrometer)
  - **node-exporter** for host metrics
  - **cAdvisor** for container metrics
- **Alertmanager** sends alerts to Slack.
- **Grafana** is provisioned from code: the datasources and the dashboard [`monitoring/grafana-dashboard.json`](monitoring/grafana-dashboard.json) are loaded at startup, so no clicking is needed.

| File | Purpose |
|---|---|
| [`monitoring/prometheus.yml`](monitoring/prometheus.yml) | Scrape targets and rule loading |
| [`monitoring/alert-rules.yml`](monitoring/alert-rules.yml) | Alert definitions |
| [`monitoring/alertmanager.yml`](monitoring/alertmanager.yml) | Routing to Slack, grouping, inhibition |
| [`monitoring/grafana-dashboard.json`](monitoring/grafana-dashboard.json) | "Todo App - Overview" dashboard |
| `monitoring/grafana/provisioning/` | Grafana datasource and dashboard provisioning |

## 1. Which metrics we monitor, and why

The approach is to measure **what users feel** first (RED: Rate, Errors, Duration), then **what's about to run out** (USE: Utilization and Saturation of host and containers).

| Dashboard row | Metric (PromQL source) | Why it matters |
|---|---|---|
| **Application** | `up{job="backend"}` | Is the backend alive and reachable at all? |
| | Request rate: `rate(http_server_requests_seconds_count)` by method, uri, status | Traffic baseline. A sudden drop to zero is as suspicious as a spike. |
| | Error rate: 5xx/total and 4xx/total | 5xx = our fault. 4xx tracked separately as a signal of client or frontend bugs. |
| | Latency p50/p95/p99: `histogram_quantile` over `http_server_requests_seconds_bucket` | Averages hide pain. p95/p99 show the slow tail users actually hit. Histograms are enabled in `application.properties`. |
| | `process_uptime_seconds` | A reset means a restart. Correlate it with deploys. |
| | JVM heap used vs max | Leak or undersized heap. Heap close to max leads to GC thrash, then OOM, then a restart. |
| | HikariCP active / idle / **pending** connections | The earliest signal of DB trouble. Pending > 0 means requests are queuing for RDS before they start failing. |
| **Host** | CPU %, memory available %, root disk % (node-exporter) | t3 instances are burstable, so sustained CPU burns credits. Docker images and logs fill disks. |
| **Containers** | Restarts in the last hour, uptime per container (`container_start_time_seconds`) | Detects crash loops that `restart: unless-stopped` would otherwise hide. |
| | CPU and memory working set per container (cAdvisor) | Shows *which* container is eating the host, and how close each is to its `mem_limit`. |
| **Alerts** | Alert list panel | What's firing right now, on the same screen. |

The `/summarize` endpoint calls Cohere and Slack, so its latency is dominated by a third party. It appears in the per-endpoint graphs but is **excluded from the latency alert**, so a slow external API doesn't page us for our own SLO.

## 2. Which logs are critical

All containers log to stdout and stderr, using Docker's `json-file` driver rotated at 10 MB × 3 files per container. That rotation is what stops logs from filling the disk.

| Log | Where | What to look for |
|---|---|---|
| **Backend application log** | `docker compose logs backend` | Startup failures (missing env, can't reach DB). Stack traces from `TodoController.summarizeAndSendToSlack`, e.g. Cohere 401/429 or Slack failures. `HikariPool ... Connection is not available` means DB saturation or an outage. `OutOfMemoryError`. |
| **nginx access and error logs** | `docker compose logs frontend` | 502/504 to `/api/` (backend down or slow), unusual traffic patterns, and the client IP via `X-Forwarded-For`. |
| **Deploy log** | GitHub Actions run (SSM output is echoed there), and SSM Run Command history in the console | Which SHA was deployed, by which run, whether the health gate passed, and whether an auto-rollback happened. This is the audit trail. |
| **Docker daemon / cloud-init** | `journalctl -u docker`, `/var/log/cloud-init-output.log` | Bootstrap failures on a new instance, and daemon crashes. |
| **RDS logs** | RDS console → Logs (error log; enable the slow query log in the parameter group if needed) | Failovers, restarts, slow queries. |
| **CloudTrail** | AWS console | Who changed what: security groups, SSM parameters, IAM. Critical in the leaked-secret scenario. |

SQL logging (`spring.jpa.show-sql`) is **off by default** in production because it is noisy and can include data. Enable it temporarily with `SPRING_JPA_SHOW_SQL=true`.

Next step if this grows: ship logs off the box with Loki + Promtail, or the CloudWatch agent. Today the logs die with the instance, which is acceptable at this scale and noted as a known limit.

## 3. Which alerts matter, and which should *not* alert

**Principle:** an alert must be **actionable and urgent**. If nobody needs to do anything right now, it belongs on a dashboard, not in Slack. Every rule has a `for:` duration, so one bad scrape or a short spike doesn't page anyone.

### Alerts we have ([alert-rules.yml](monitoring/alert-rules.yml))

| Alert | Condition | Severity | Why it's worth waking someone |
|---|---|---|---|
| `BackendDown` | `up == 0` for 2 min | critical | The app is fully down for users. |
| `HighErrorRate` | 5xx > 5% of API traffic for 5 min, **and** traffic > 0.1 req/s | critical | Users are getting errors. This also covers RDS outages. The traffic floor stops a single failed request at 3 a.m. (1 of 1 = 100%) from paging. |
| `HighLatencyP95` | p95 of the CRUD API > 1 s for 10 min | warning | Users notice that it's slow. |
| `ContainerRestarting` | > 2 restarts in 15 min | warning | A crash loop, which auto-restart would otherwise mask. |
| `HighCpu` | > 90% for 15 min | warning | Sustained load. Burstable instances throttle once credits run out. |
| `LowMemory` | < 10% available for 10 min | warning | The OOM killer is next. |
| `LowDiskSpace` | root < 15% free for 10 min | warning | A full disk breaks Docker pulls, logs, and Prometheus. |

**Noise control in Alertmanager:**

- Alerts are grouped by `alertname`.
- `repeat_interval` is 4 h.
- `send_resolved` is on, so people know when they can stop looking.
- **Inhibition:** while `BackendDown` is firing, `HighErrorRate` and `HighLatencyP95` are suppressed. Those are symptoms of the same root cause, so one page is enough.

### Things we deliberately do *not* alert on

| Signal | Why not | Where it lives instead |
|---|---|---|
| A single container restart | Docker already recovered. Only a *loop* is actionable. | Dashboard restarts table |
| Brief CPU spikes (builds, JIT warm-up, GC) | Normal and self-resolving | Host panel |
| 4xx responses | Usually client input, e.g. updating a deleted todo. We can't fix users' requests. | Error-rate panel (4xx series) |
| JVM heap high but stable | The JVM uses heap by design. GC is doing its job. | JVM heap panel. OOM shows up as a restart anyway. |
| `/summarize` latency or failures from Cohere or Slack | A third-party outage we can't fix at 3 a.m. Failures still count toward `HighErrorRate` if they become widespread. | Per-endpoint panels |
| Individual deploys | Not an incident. CI already reports success or failure. | GitHub Actions |
| Prometheus, Grafana or exporter self-metrics | Meta-monitoring noise for a single-host setup | `up` in Prometheus targets page |

## 4. How operational issues are detected early

1. **Before production:** tests run on every PR and push, against a real MySQL. Images are built on PRs too, so a broken Dockerfile never reaches `main`.
2. **At deploy time:** `deploy.sh` checks Docker health (which includes DB connectivity via `/actuator/health`) and a real request through nginx. A bad version is rolled back automatically, before most users ever see it. The pipeline then runs a second health check from outside AWS, which also proves the security group and DNS path work.
3. **Leading indicators before user impact:**
   - HikariCP *pending* connections rise **before** requests time out, which gives early warning of RDS trouble.
   - p95 latency usually degrades **before** error rate climbs.
   - Memory and disk trends are visible days ahead on the host panel. The `LowDiskSpace` threshold of 15% leaves time to react.
   - Container restarts are counted even when Docker hides them by auto-restarting.
4. **Continuous:** Prometheus evaluates rules every 15 s, and Alertmanager pushes to Slack, so nobody has to watch a dashboard to find out.
5. **Routine:** a weekly glance at the dashboard for trends (disk growth, memory creep, traffic changes), a quarterly RDS restore test, and a review of any alert that fired but needed no action. That alert gets tuned or deleted.

## Runbook quick reference

```bash
# on the host:  aws ssm start-session --target <instance-id>
cd /opt/todo-app
sudo docker compose ps                         # what's running / healthy
sudo docker compose logs --tail 200 backend    # app errors
cat .deployed_tag                              # currently deployed SHA
sudo bash scripts/deploy.sh <sha>              # deploy / roll back to any built SHA
df -h / && free -m                             # disk & memory
sudo docker image prune -af --filter until=168h
```

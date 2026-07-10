# statuswatch — How Everything Hooks Together

A from-first-principles walkthrough of the system you're deploying. Written to be studied, not skimmed: every component is explained as if you'd never met it, then connected to the reason it exists here. Read it once tonight, once after the deploy, and once before any interview where this project comes up.

## 0. The one-paragraph version

Every two minutes, a scheduler wakes a small program that asks 35 vendors' status pages "how are you?" all at once. Each answer is saved twice: the exact raw bytes go to cheap object storage (so a parsing bug can never destroy evidence), and a cleaned, normalized summary goes onto a queue. A second small program drains that queue, writes the normalized facts into a relational database (the system of record), and then publishes a single small JSON file — the current state of the internet's vendors — to a bucket that a CDN will eventually serve to the world. The two programs never talk to each other directly; the queue between them is the seam that lets either one fail, restart, scale, or be replaced without the other noticing.

## 1. The cast of characters

Before the flow, meet each AWS service as a plain idea.

**Lambda** is "run my function when something happens, on hardware I never see." You upload a zip containing code; AWS keeps it on ice; when triggered, AWS thaws a copy (a "cold start," ~1–3 seconds), runs your handler function, and may keep the copy warm for subsequent triggers. You pay per invocation and per millisecond of runtime — zero when idle. The mental model from your world: a Pod that only exists for the duration of one request, scheduled by AWS instead of kubelet.

**EventBridge** here is just managed cron. `rate(2 minutes)` is a rule that fires an event on a schedule, and the event's target is the poller Lambda. Same concept as a Kubernetes CronJob, different substrate: no cluster required, and AWS guarantees the tick happens.

**S3** is a key-value store for blobs: you PUT bytes at a key like `raw/github/20260710/031502.json`, you GET them back later. No filesystem, no server, eleven nines of durability, pennies per GB. Two buckets here with two jobs: `raw` (evidence locker) and `data` (the published product).

**SQS** is a mailbox between programs. Producers put messages in; consumers take messages out; the mailbox itself is durable, so a message survives even if no consumer is alive when it arrives. Crucially, consuming is two-phase: a consumer *receives* a message (which hides it from others for a "visibility timeout") and must explicitly *delete* it after successful processing. If the consumer crashes mid-work, the message reappears after the timeout and gets retried. That receive-process-delete loop is the entire reliability story of the pipeline's second half.

**RDS** is a managed Postgres server: AWS owns the hardware, the OS patching, the backups; you own the schema and queries. Unlike everything else in this stack, it's a *server* — always on, hourly billed — which is why it's the dominant cost. It's here because this product's data (incident history, uptime records) is the product, and relational queries over time ("show me GitHub's incidents in March") is exactly what SQL is for.

**VPC** is your private slice of the AWS network — an IP range you own (10.61.0.0/16 here) divided into subnets, with routing rules you write. Things inside a VPC can only reach what the route tables and security groups allow. Our VPC is deliberately a sealed room: no door to the internet at all.

**Security groups** are per-resource firewalls expressed as "who may talk to whom." Ours say exactly one thing: the Lambda security group may reach the RDS security group on port 5432. Nothing else gets in.

**IAM roles** answer a different question than security groups: not "what network paths exist" but "what API calls is this identity allowed to make." Each Lambda wears a role like a badge; the poller's badge says "you may PutObject into the raw bucket and SendMessage to this one queue" and nothing more. This is least privilege as three small JSON documents.

## 2. The map

```
        ALWAYS-ON PIPELINE (persistent — never torn down)

  ┌────────────┐   rate(2 min)   ┌──────────────────┐
  │ EventBridge├────────────────►│  poller Lambda    │   lives OUTSIDE the VPC
  └────────────┘                 │  (aiohttp, async) │   → free internet egress
                                 └───┬──────────┬────┘
                 35 concurrent HTTPS │          │
                 requests to vendor  │          │
                 status APIs         │          │
                        ▼            │          │
              github, cloudflare,    │          │
              datadog, aws, gcp...   │          │
                                     │          │
             raw bytes, verbatim     │          │  one JSON message
                        ┌────────────▼───┐  ┌───▼──────────────┐
                        │ S3: raw bucket │  │ SQS: observations │──► DLQ (after
                        │ (90-day expiry)│  │ queue             │    3 failures)
                        └────────────────┘  └───┬───────────────┘
                                                │ event source mapping
                                                │ (batches of ≤10)
        ┌───────────────────────────────────────▼──────────────┐
        │              VPC 10.61.0.0/16 — sealed room           │
        │   no internet gateway, no NAT gateway                 │
        │                                                       │
        │   ┌────────────────────┐        ┌──────────────────┐  │
        │   │ normalizer Lambda  │──5432──│ RDS Postgres      │  │
        │   │ (psycopg2)         │        │ db.t4g.micro      │  │
        │   └─────────┬──────────┘        │ 7-day backups     │  │
        │             │                   └──────────────────┘  │
        │             │ S3 GATEWAY ENDPOINT (free, in-VPC       │
        │             ▼ route to S3 — no internet needed)       │
        └─────────────┼─────────────────────────────────────────┘
                      ▼
             S3: data bucket ── status.json (rewritten every cycle)
                      │
                      ▼  (Phase 3)
             CloudFront ──► status.shanedoolabh.com ──► the world
```

The migrate Lambda isn't on the map because it runs once: it sits inside the VPC purely so *something* can reach the private database to apply `schema.sql`, since your laptop deliberately cannot.

## 3. Life of one poll cycle, in slow motion

**T+0s — the tick.** EventBridge's rule fires. It calls the Lambda service: "invoke statuswatch-poller." (The `aws_lambda_permission` resource in Terraform is what authorizes EventBridge to do this — in AWS, even AWS services need explicit permission to poke each other.)

**T+0.1s — the poller wakes.** If a warm copy exists, it runs immediately; if not, AWS unzips your code onto a fresh micro-VM (cold start). The handler loads `vendors.yaml` — the same file from your repo, copied into the zip by `make package` — and gets 35 enabled vendors.

**T+0.2s to ~5s — the fan-out.** `poll_all()` uses Python's asyncio with aiohttp: all 35 HTTPS requests are in flight *concurrently*, capped at 12 at a time by a semaphore, each with a 10-second timeout. This is why one hung vendor can't stall the cycle — the requests are independent, and the slowest vendor bounds the cycle, not the sum. Each adapter turns its vendor's dialect into the same `Observation` shape: a normalized status, a list of incidents, the raw bytes, the latency, or — if anything went wrong — status `unknown` with the error recorded. The design rule: no exception escapes an adapter. An unreachable status page is *data* ("we could not observe GitHub"), never a crash.

**T+~5s — raw archiving.** For each observation, the exact bytes the vendor sent are PUT to the raw bucket under `raw/{vendor}/{date}/{time}.json`. This happens *before* any downstream parsing matters, and it's the discipline that saved you three times already (UTF-16 BOM, mixed epoch units, unmaintained transitions — all diagnosable because the evidence existed). The bucket has a lifecycle rule expiring objects after 90 days, so the evidence locker never grows unboundedly.

**T+~6s — enqueue.** Each observation is serialized to JSON — status, incidents with ISO-formatted timestamps, latency, error, and the S3 key of its raw payload (the raw bytes themselves stay in S3; SQS messages are capped at 256KB) — and sent to the queue in batches of 10 (SQS's batch API limit). The poller then exits. Its total lifespan: seconds. Its bill for the invocation: a fraction of a cent.

**T+~6s onward — the handoff.** Here's a subtlety worth being able to explain: *the normalizer does not poll SQS from inside your VPC.* The "event source mapping" means the **Lambda service itself** polls the queue on its own network, and when messages arrive, it invokes the normalizer with a batch of up to 10 (waiting at most 5 seconds to fill a batch). This is why the sealed-room VPC works: the function's code never needs a network path to SQS — messages arrive as the function's input argument.

**T+~7s — normalize and persist.** The normalizer (warm connection to Postgres reused across invocations — the `_conn` global) processes each message: append a row to `status_snapshots`; upsert each incident on `(vendor_slug, provider_incident_id)` so a vendor updating an incident updates our row instead of duplicating it (and a resolved incident gets its `resolved_at` backfilled — you watched this self-heal the stale AWS outages); insert any new timeline entries into `incident_updates`; and update `poll_health` — success resets the failure counter, failure increments it and records the error. That table is the pipeline watching itself, and later it becomes both the public health page and the Grafana SLOs.

**T+~8s — materialize.** After the batch, the normalizer runs one query for the latest snapshot per vendor and one for unresolved incidents, renders `status.json`, and PUTs it to the data bucket with `Cache-Control: max-age=60`. The write leaves the VPC through the S3 *gateway endpoint* — a free routing-table entry that sends S3-bound traffic across AWS's internal network, which is the trick that lets the sealed room talk to S3 without any internet path.

**T+120s — again.** Forever. Unattended. That's the product's heartbeat.

## 4. Why it's shaped this way — the decisions and their defenses

**Why two Lambdas instead of one?** Separation by *need*. The poller needs internet; the normalizer needs the database. Marrying them would force one function to have both — and a Lambda inside a VPC only gets internet through a NAT gateway (~$35/month, doubling the system's cost) — while divorcing them costs one SQS queue (~free). The queue also buys durability (an RDS outage doesn't lose observations; they wait in the queue), independent retry semantics, and a portability seam: the normalizer is "a function that eats queue messages," which could be re-homed to a Kubernetes Deployment consuming the same queue without touching the poller. That's your honest answer to "why isn't the pipeline on Kubernetes?" — the streaming half is serverless because always-on coverage at near-zero cost matters more than substrate purity; the batch half (rollups, backfills) lands on K8s in Phase 4 where it belongs.

**Why is the VPC sealed?** Because nothing inside it needs the internet. The database should never be publicly reachable — it isn't, by construction: no internet gateway exists, so there is no path, which is stronger than "there's a path but a firewall blocks it." The one consequence: your laptop can't reach the DB either, which is why schema changes ride the migrate Lambda. Attack surface traded for a small operational ritual — say it exactly like that.

**Why raw-before-parse?** Because parsers are the most likely thing to be wrong, and the AWS adapter proved it thrice in one evening. If a vendor changes format tomorrow, the pipeline degrades to `unknown` for that vendor, the raw payloads keep accumulating, and after fixing the adapter you can *replay* history from the archive. Transforms should never be the only copy of anything.

**Why Postgres and not DynamoDB?** The product's queries are relational and temporal: incidents per vendor over time, uptime percentages per day, joins between snapshots and incidents. That's SQL's home turf. DynamoDB would force modeling those access patterns up front; Postgres lets the Phase 4 API ask questions you haven't thought of yet. Cost is the tradeoff (RDS is the only "server" in the stack), paid deliberately because this data *is* the product — hence also the 7-day automated backups and final-snapshot-on-destroy.

**Why does `status.json` exist at all, if the database has everything?** Availability partitioning — the deepest idea in the design. A status site is most needed when things are broken, possibly including your own components. So the core product (current status) is materialized into a static file served by S3/CloudFront, an availability tier that effectively cannot go down and costs nothing to serve at any scale. The database, the API, the future EKS cluster can all be down and the 2am question still gets answered. Rich history requires the query layer; the glance does not. Partition the system by what must never blink.

**Where's the failure handling?** Everywhere, layered: adapter level (fail soft to `unknown`), poll level (concurrent isolation + timeouts), queue level (visibility timeout means a crashed normalizer's messages reappear and retry; after 3 failed attempts a message parks in the dead-letter queue for 14 days so a poison message can't loop forever and you can autopsy it), data level (upserts are idempotent — reprocessing a message is harmless, which matters because SQS guarantees *at-least-once* delivery, not exactly-once), and observability level (`poll_health` records every vendor's consecutive failures and last error). Idempotent consumers plus at-least-once delivery is the classic distributed-systems pairing — be ready to say that sentence.

## 5. Security posture, honestly stated

Least-privilege IAM per function: the poller can write one S3 prefix and send to one queue; the normalizer can consume one queue and write one bucket; nobody can do anything else. Network isolation by absence: the DB has no internet path in either direction. The known soft spot, documented in `storage.tf`: the DB password lives in Terraform state and Lambda environment variables. For a solo project with a private, versioned state bucket this is a reasoned tradeoff; the production upgrade is Secrets Manager with rotation, which requires a paid VPC interface endpoint (~$7/mo) from the sealed subnets. You've done that migration professionally (Vault → ASM at Flow) — when asked, name the tradeoff, the price of fixing it, and the fact that you chose consciously. Deliberate deferrals stated plainly read as seniority; hidden ones read as gaps.

## 6. What it costs and why

| Component | ~Monthly | Why it costs that |
|---|---|---|
| RDS db.t4g.micro + 20GB gp3 | ~$14–15 | the only always-on server |
| Lambda (21,600 poller runs/mo + normalizer) | ~$1–2 | pay-per-use, seconds at a time |
| S3 (raw w/ 90-day expiry + data) | ~$1 | pennies per GB |
| SQS, EventBridge, CloudWatch logs (30-day retention) | ~$1–2 | rounding error |
| **Always-on total** | **~$17–19** | |

The EKS layer (Phase 4) adds ~$35–110 depending on schedule — and can be destroyed and rebuilt at will *because* the persistent layer above holds all the state. That sentence is the whole persistent/cattle philosophy.

## 7. What comes next, so the story has an arc

Phase 3 puts CloudFront in front of the data bucket with the React status grid at `status.shanedoolabh.com` — the product goes public. Phase 4 adds the destroyable EKS stack via ArgoCD app-of-apps: the FastAPI history API reading RDS, Prometheus + Grafana turning `poll_health` into freshness SLO dashboards, and the nightly `uptime_daily` rollup as a K8s CronJob. Phase 5 is polish: public API docs, the health page, the launch post.

## 8. Interview drill — answer these cold before presenting

Why doesn't the poller live in the VPC? (NAT economics + it needs nothing inside.) How does the normalizer receive messages with no internet? (Event source mapping — the Lambda service polls, messages arrive as input.) What happens if RDS is down for an hour? (Observations queue up; visibility timeout + retries drain the backlog on recovery; current-status file goes stale but the site stays up — and staleness is visible via `generated_at`.) What if a vendor sends garbage? (Adapter fails soft to `unknown`, raw evidence archived, `poll_health` records it; if a message still poisons the normalizer, DLQ after 3 tries.) Why can the same message be processed twice safely? (At-least-once delivery, idempotent upserts.) How do you change the schema? (Migrate Lambda — nothing outside the VPC can reach the DB, on purpose.) Why S3 for raw instead of a Postgres column? (Cost, size, lifecycle expiry, and replay-ability decoupled from the DB.) What breaks at 500 vendors? (Poller fan-out and SQS scale fine; the per-cycle materialize query and single normalizer batch size become the tuning points; RDS vertical headroom after that.)

If you can answer those eight without notes, you don't just have a project — you have a system you understand down to the studs.
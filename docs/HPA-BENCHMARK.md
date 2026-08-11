# HPA benchmark report (poc-realm)

This report captures the HPA lab run on CRC using the `poc-realm` workload and `AuthorizationCode` scenario from keycloak-benchmark.

## Test setup

- Keycloak CR: `manifests/hpa/keycloak-scalable.yaml` (stateless, HPA-enabled)
- HPA policy: `manifests/hpa/keycloak-hpa-cpu.yaml` (`minReplicas: 1`, `maxReplicas: 4`, CPU target `80%`)
- Realm/client: `poc-realm` + `poc-load` (confidential)
- Target paths:
  - direct: `https://auth.lan.local:443/`
  - haproxy: `https://auth.lan.local:8443/`
- Matrix script: `scripts/run-hpa-matrix.sh`
- Benchmark script: `scripts/run-hpa-benchmark.sh`
- Final run log: `benchmark-results/matrix-run-final-timeboxed-20260811T191209Z.log`
- Final matrix summary: `benchmark-results/matrix-summary-20260811T191209Z.md`

## Preconditions used

1. `oc adm top nodes` available (metrics-server healthy)
2. `bash scripts/disable-sync-replication.sh` (Site B down safety)
3. HAProxy health check passed: `curl -sk https://127.0.0.1:8443/lb-check`
4. Keycloak can run with a 1-pod idle baseline and scale out during load

## Baseline footprint (idle)

At idle with 2 Keycloak pods before load, observed baseline from footprint snapshots was approximately:

- CPU: single-digit millicores to low tens of millicores per pod
- Memory: ~720-740Mi per pod
- HPA state: `2` replicas, low CPU utilization relative to target

## Matrix results

Run date: `2026-08-11T19:12:09Z`  
Scenario: `AuthorizationCode`  
Ramp: `100,250,500,1000`  
Measurement: `60s` per level

| target | concurrent | mean ms | rps | KO notes | pods | hpa cpu% |
|---|---:|---:|---:|---|---:|---:|
| direct | 100 | 435 | 194.48 | KO=12529 | 4 | 185 |
| direct | 250 | 5691 | 78.00 | none in summary | 4 | 360 |
| direct | 500 | 2848 | 166.89 | KO=8399 | 4 | 297 |
| direct | 1000 | 3667 | 244.58 | KO=7 | 4 | 321 |
| haproxy | 100 | 397 | 202.39 | none in summary | 4 | 337 |
| haproxy | 250 | 800 | 288.90 | KO=1 | 4 | 315 |
| haproxy | 500 | 1759 | 241.65 | KO=2 | 4 | 294 |
| haproxy | 1000 | 3911 | 200.27 | KO=3 | 4 | 316 |

Notes:

- HPA quickly scaled to max replicas (`4`) and stayed there for all heavier ramps.
- CPU remained far above target during heavy ramps, so scaling was maxed out (`ScalingLimited: TooManyReplicas` behavior).
- KO counts and high p95/p99 latencies indicate CRC saturation at higher concurrency, not enough capacity headroom for this target on current limits.

## Recommendation

Use CPU-based HPA as the primary policy for this lab:

- CPU signal reacts quickly to auth load and correctly drives scale-out behavior.
- Memory stays high and relatively flat per pod, so memory-only HPA is less predictive for immediate login bursts.

Suggested tuning for next iteration:

1. Keep CPU HPA as default with `minReplicas: 1` for lower idle footprint.
2. Increase per-pod CPU request/limit and evaluate if reduced throttling lowers tail latency.
3. If CRC memory pressure appears, cap `maxReplicas: 3` for local runs and compare throughput tradeoff.
4. Add one memory-HPA A/B run at `500` concurrency to quantify CPU-vs-memory policy differences.

## Optimized startup note

- The scalable CR is configured for `startOptimized: true` and must use a prebuilt optimized Keycloak image.
- Benefit: shorter startup path during scale-out and restarts.
- Tradeoff: with `minReplicas: 1`, first burst after idle may still see cold-start latency while HPA scales out.
- If startup fails, verify the image was built for optimized startup and re-apply with:
  - `OPT_IMAGE=<your-prebuilt-optimized-tag> bash scripts/apply-hpa-lab.sh cpu`

## Startup A/B (clean measurement)

Measured on `2026-08-11` with a dedicated `keycloak-ab` CR and isolated databases:

- Non-optimized:
  - image: `quay.io/keycloak/keycloak:26.7.0`
  - `startOptimized: false`
  - database: `keycloak_ab_nonopt`
  - pod ready wait: `36s`
- Optimized:
  - image: `default-route-openshift-image-registry.apps-crc.testing/rhbk-mc/keycloak:26.7.0-optimized`
  - `startOptimized: true`
  - database: `keycloak_ab_opt`
  - pod ready wait: `26s`

Observed delta:

- `10s` faster with optimized image
- `27.78%` startup time reduction vs non-optimized

Raw artifact:

- `benchmark-results/startup-ab-clean-20260811T204202Z.json`

Notes:

- A separate namespace (`rhbk-mc-ab`) was created for isolation, but the current operator scope reconciles in `rhbk-mc`; therefore the timed A/B CR was executed as `keycloak-ab` in `rhbk-mc` while keeping full DB isolation per run.

## Artifacts

- Matrix summary: `benchmark-results/matrix-summary-20260811T191209Z.md`
- Run log: `benchmark-results/matrix-run-final-timeboxed-20260811T191209Z.log`
- Per-step reports and footprints: `benchmark-results/*-AuthorizationCode-c*/`

## References

- [Keycloak horizontal autoscaling guide](https://www.keycloak.org/getting-started/getting-started-scaling-and-tuning#_horizontal_autoscaling)
- [Keycloak benchmark project](https://github.com/keycloak/keycloak-benchmark)

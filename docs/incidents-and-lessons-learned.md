# Known Issues and Lessons Learned

Real incidents and troubleshooting encountered while building and operating this stack, kept here as evidence of actual debugging work rather than a clean-room writeup. Each entry links to the commit that fixed it.

## Observability stack

### Grafana resource starvation → restart loop

**Symptom:** Grafana entered a restart loop; the liveness probe was timing out (`context deadline exceeded`) and the container was being SIGKILLed (exit 137).

**Root cause:** The chart's default sizing (100m/128Mi requests, 250m/256Mi limits) was too tight once all three provisioned dashboards, both `k8s-sidecar` containers (dashboard + datasource provisioning), and Grafana's own unified-storage (bleve) indexing were running in the same pod. Observed CPU pegged at the 250m limit and memory over the 256Mi limit.

**Fix:** Raised `grafana.resources` to 150m/256Mi requests and 500m/512Mi limits, sized against real observed usage rather than guessed. Documented inline in `helm/kube-prometheus-stack/values.yaml`.

**Commit:** `AWS-DevOps-Observability` `2d433e3`

### Wrong Jenkins metric name in a PrometheusRule and a Grafana panel

**Symptom:** The `JenkinsQueueStuck` alert could never fire, and the "Build Queue Length" Grafana panel always showed "No data" — despite a real, growing queue backlog.

**Root cause:** Jenkins exposes two separate metric-naming families depending on the plugin/exporter path: `default_jenkins_*` (builds, executors, nodes) and plain `jenkins_*` (queue, health checks, tasks). Both the alert rule and the dashboard panel had been written against `default_jenkins_queue_size_value`, which was never actually scraped — the real metric is `jenkins_queue_size_value`.

**Fix:** Corrected the `expr` in both `prometheus/rules/jenkins-alerts.yaml` and `grafana/dashboards/jenkins-delivery.json`, reapplied via `kubectl apply` / the dashboard ConfigMap pattern. Verified against a real queue-backlog exercise (see `evidence/04-failure-exercises/c-jenkins-agent-delay/00-findings.md`).

**Commit:** `AWS-DevOps-Observability` `77c3846`

## Application instrumentation

### `endpoint` label collision with Prometheus's reserved target-identity label

**Symptom:** The `route` dimension on `http_requests_total`/`http_request_duration_seconds` was silently showing up as `exported_endpoint` in Prometheus instead of the intended label name.

**Root cause:** Prometheus reserves `endpoint` as a target-identity label, populated from the PodMonitor's named port (`"metrics"`). The app's own metrics used `endpoint` for the HTTP route path, and Prometheus's collision handling (`honor_labels: false`) silently renamed the app's label to `exported_endpoint` on scrape rather than erroring.

**Fix:** Renamed the label to `route` in both `backend` and `worker` instrumentation, avoiding the collision entirely.

**Commit:** `AWS-DevOps-Kubernetes` `9305443`

## CI/CD pipeline

### Jenkins durable-task couldn't launch a shell in the minimal `promtool` image

**Symptom:** The `observability-ci` pipeline's PrometheusRule-validation stage failed — Jenkins couldn't execute steps inside the `prom/prometheus` container.

**Root cause:** Jenkins's durable-task plugin needs to launch a shell inside a container to run pipeline steps; the official `prom/prometheus` image is a minimal busybox-based image with no usable shell for that purpose.

**Fix:** Replaced the dedicated `promtool` container with a `curl`-downloaded `promtool` binary run inside the existing `kubectl` container (which does have a proper shell), avoiding the extra minimal-image container entirely.

**Commit:** `AWS-DevOps-Jenkins-CICD` `a96b1ed`

### ECR image pull secret expiry → `ImagePullBackOff`

**Symptom:** Deployments intermittently failed with `ImagePullBackOff` on the app's images, even though the images existed in ECR and had built/pushed successfully.

**Root cause:** ECR authorization tokens are short-lived (12 hours); the `imagePullSecret` used by the cluster to pull from ECR was created once and went stale, so pulls started failing once enough time had passed since it was last refreshed.

**Fix:** The CD pipeline now refreshes the ECR `imagePullSecret` on every run before rollout, with RBAC scoped specifically to that operation, and forces a `kubectl rollout restart` so pods pick up the refreshed secret.

**Commit:** `AWS-DevOps-Jenkins-CICD` `46dd2af`

### ECR token leaking into Jenkins console log

**Symptom:** The raw ECR authorization token was visible in plaintext in the Jenkins build console output — a credential-exposure risk for anyone with read access to build logs.

**Fix:** Reworked the relevant pipeline step so the token is piped directly into the login command rather than echoed or captured in a way that surfaces it in console output.

**Commit:** `AWS-DevOps-Jenkins-CICD` `72119d8`

### ECR credentials Secret silently populated with literal `"null"`

**Symptom:** ECR push authentication started failing with `401 Unauthorized` immediately after `configure-jenkins.sh`'s first run.

**Root cause:** `configure-jenkins.sh` read `.AccessKeyId`/`.SecretAccessKey` at the top level of the IAM access-key JSON file, but that file has the shape of raw `aws iam create-access-key` output — the fields are nested under `.AccessKey`. `jq` silently returned `null` for both paths, and the script wrote the literal string `"null"` into the Kubernetes Secret instead of failing.

**Fix:** Corrected the `jq` paths, added a guard so the script now fails loudly instead of silently writing a broken credential, and corrected the documented access-key file shape in the README. Verified via a full CI+CD run (build #21): both images pushed, ECR scan completed, deploy succeeded.

**Commit:** `AWS-DevOps-Jenkins-CICD` `90452f5`

### Kaniko cross-image filesystem contamination

**Symptom:** The `worker` image was occasionally missing the `flask` dependency, despite `requirements.txt` listing it correctly.

**Root cause:** The `backend` and `worker` Kaniko builds were sharing build-context/filesystem state, letting artifacts from one image's build leak into the other's.

**Fix:** Isolated the two builds into separate containers, and added `--cleanup` to each Kaniko build to prevent filesystem contamination from carrying over between runs.

**Commits:** `AWS-DevOps-Jenkins-CICD` `2c0da26`, `bade26c`

## Repository organization

### Jenkins namespace NetworkPolicy relocated to the Jenkins-CICD repo

Originally placed in the Kubernetes repo alongside the application's own NetworkPolicy, it was moved to `AWS-DevOps-Jenkins-CICD/network/jenkins-networkpolicy.yaml` on the reasoning that it's Jenkins infrastructure, not an application manifest the CD pipeline should blindly apply alongside app changes — keeping the repo boundaries aligned with what each pipeline is actually responsible for deploying.

**Commit:** `AWS-DevOps-Kubernetes` `2db93ea`
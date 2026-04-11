# ELK SIEM on K3s — Home Lab Setup
**Subhrajit Pallob | DevSecOps Home Lab**

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  K3s Cluster (elk-siem namespace)   │
│                                                     │
│  ┌─────────────────┐    ┌──────────────────────┐    │
│  │ Filebeat        │    │ node-exporter        │    │
│  │ (DaemonSet)     │    │ (DaemonSet)          │    │
│  │ /var/log/pods/  │    │ port 9100/metrics    │    │
│  │ auth.log        │    └──────────┬───────────┘    │
│  │ k8s audit logs  │               │ scrape         │
│  └────────┬────────┘    ┌──────────▼───────────┐    │
│           │ beats:5044  │ Prometheus            │    │
│  ┌────────▼────────┐    │ (Deployment)         │    │
│  │ Logstash        │    │ :9090 NodePort:30909 │    │
│  │ (Deployment)    │    └──────────┬───────────┘    │
│  │ Geo-IP, Grok    │               │                │
│  └────────┬────────┘    ┌──────────▼───────────┐    │
│           │ index       │ Grafana               │    │
│  ┌────────▼────────┐    │ (Deployment)         │    │
│  │ Elasticsearch   │    │ :3000 NodePort:30300 │    │
│  │ (StatefulSet)   │    │ Node Exhaustion Dash │    │
│  │ es-0, es-1...   │    └──────────────────────┘    │
│  │ PVC: local-path │                                 │
│  └────────┬────────┘                                 │
│           │                                         │
│  ┌────────▼────────┐                                 │
│  │ Kibana          │                                 │
│  │ (Deployment)    │                                 │
│  │ :5601 NP:30601  │                                 │
│  │ SIEM Dashboards │                                 │
│  └─────────────────┘                                 │
└─────────────────────────────────────────────────────┘
```

---

## Files

| File | What it deploys |
|---|---|
| `00-namespace.yaml` | `elk-siem` namespace |
| `01-elasticsearch.yaml` | StatefulSet + Headless Service + ClusterIP Service |
| `02-kibana.yaml` | Deployment + NodePort Service (`:30601`) |
| `03-logstash.yaml` | Deployment + ConfigMap (Geo-IP pipeline, Grok) |
| `04-filebeat-daemonset.yaml` | DaemonSet + RBAC + ConfigMap |
| `05-prometheus-node-exporter.yaml` | node-exporter DaemonSet + Prometheus Deployment + Alert Rules |
| `06-grafana.yaml` | Deployment + Node Exhaustion Dashboard + NodePort (`:30300`) |

---

## Prerequisites

```bash
# K3s must be running. Verify:
kubectl get nodes

# Verify default StorageClass (local-path)
kubectl get storageclass
# Should show: local-path (default)
```

---

## Deploy

```bash
# Apply all manifests in order
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-elasticsearch.yaml
kubectl apply -f 02-kibana.yaml
kubectl apply -f 03-logstash.yaml
kubectl apply -f 04-filebeat-daemonset.yaml
kubectl apply -f 05-prometheus-node-exporter.yaml
kubectl apply -f 06-grafana.yaml

# Or apply the entire directory at once
kubectl apply -f .
```

---

## Verify

```bash
# Check all pods are Running
kubectl get pods -n elk-siem

# Expected output:
# elasticsearch-0          1/1   Running
# kibana-xxx               1/1   Running
# logstash-xxx             1/1   Running
# filebeat-xxxxx (x nodes) 1/1   Running   <- DaemonSet: one per node
# node-exporter-xx (xN)    1/1   Running   <- DaemonSet: one per node
# prometheus-xxx           1/1   Running
# grafana-xxx              1/1   Running

# Check Elasticsearch health
kubectl exec -n elk-siem elasticsearch-0 -- curl -s localhost:9200/_cluster/health | python3 -m json.tool

# Check logs flowing into ES
kubectl exec -n elk-siem elasticsearch-0 -- curl -s "localhost:9200/siem-logs-*/_count" | python3 -m json.tool
```

---

## Access

| Service | URL |
|---|---|
| Kibana | `http://<node-ip>:30601` |
| Grafana | `http://<node-ip>:30300` (admin / homelab123) |
| Prometheus | `http://<node-ip>:30909` |

---

## Key PromQL Queries (for interview)

```promql
# Memory available % — primary OOM signal
(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# CPU usage %
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Pod restart rate — OOMKill indicator
increase(kube_pod_container_status_restarts_total[5m])

# Disk available %
(node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100
```

---

## Key Design Decisions (for interview)

**Why StatefulSet for Elasticsearch?**
Pods get stable identities (`es-0`, `es-1`). On restart, the pod reattaches to its original PVC — critical for shard integrity. A Deployment would give a new pod a new PVC, losing indexed data.

**Why DaemonSet for Filebeat and node-exporter?**
Guarantees exactly one pod per node regardless of cluster size. When nodes are added, the DaemonSet automatically schedules a new pod — no manual intervention.

**Why Local Path Provisioner?**
K3s default. Dynamically provisions PVs on the host disk. For a homelab, this beats setting up Ceph or NFS. Tradeoff: data is tied to the node (not suitable for HA without replication).

**Why headless service for Elasticsearch?**
Headless (clusterIP: None) returns individual pod IPs, allowing direct pod-to-pod communication via DNS (`es-0.elasticsearch.elk-siem.svc.cluster.local`). Required for Elasticsearch cluster transport layer.

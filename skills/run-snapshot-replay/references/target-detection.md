# Target detection: what the detector prints and why

Read on demand from `SKILL.md` step 1.

It prints JSON: `origin` (`cluster`, `local`, or `unknown`), `cluster`,
`namespace`, `workload`, `workloads`, `clusterRegistered`, `localAddress`,
`priorReport` (the last replay of this snapshot, with its `testConfig` and
`replayMode`), and `evidence`, one sentence saying why. The evidence order is
the one the dashboard's replay wizard uses to pre-fill its target:

1. The newest earlier replay of this snapshot (report tags `k8sClusterName`,
   `ns`, `workload`).
2. The snapshot's metadata: `meta.namespaces[].inspector.clusterName` and
   `name`, plus `meta.serviceName`.
3. The recorded inbound RRPairs' tags: `k8sClusterName`,
   `k8sAppPodNamespace`, `k8sAppLabel` mean cluster capture. No cluster tags
   means a local proxymock recording; the target address is the busiest
   inbound slice from `proxymock cluster replay prepare`.

# Documentation

[English](README.en.md) | [简体中文](README.zh.md) | [繁體中文](README.zh-TW.md)

## Current behavior

Read the documents shipped with your release; source `main` may describe newer behavior.

| Owner | Maintained content |
| --- | --- |
| [Architecture](architecture.en.md) | Scope, component boundaries, state ownership and design rationale |
| [Operations](operations.en.md) | Configuration, deployment, sizing, observability and troubleshooting |
| [Protocol](protocol.en.md) | Request/response/stream semantics and conversion limits |
| [Routing](routing.en.md) | Pool selection, entitlement, affinity, binding, RPM and concurrency |
| [Compatibility](../compatibility/README.md) | Fixed client contracts, evidence collection and release qualification |

## Runbooks

- [Azure / Linux VM operations (Traditional Chinese)](runbooks/azure-vm-operations.zh-TW.md)
- [Kubernetes procedures](../deploy/k8s/README.en.md)
- [Manual validation (Simplified Chinese)](runbooks/manual-validation.zh.md)

## Active plans and proposals

- [Cluster deployment plan](plans/cluster-deployment.zh.md)
- [Compatibility roadmap](plans/compatibility-roadmap.zh.md)
- [OpenCode authentication: remaining target validation](plans/opencode-upstream-auth.zh.md)
- [Ultra performance proposal (not implemented)](proposals/ultra-performance.zh.md)

## Maintenance rules

- Code and reproducible tests decide implemented behavior; [migrations](../migrations/) decide the deployed schema. The [matrix](../compatibility/matrix.json) sets static client contracts and maximum candidate levels; a release-specific, non-committed attestation determines the effective level of one immutable release.
- Maintain each detailed contract in its owner above. Entry pages and translations should link to it, not repeat model inventories, API tables, prices, or full validation logs.
- Plans contain remaining work, acceptance gates and stop conditions; runbooks contain repeatable procedures. A plan or proposal is not evidence of implemented or production-approved behavior.
- Move lasting rationale into its owner, then remove completed plans and execution logs. Git history retains past implementation and test records; no parallel `docs/history` archive is required.
- New compatibility cases need an existing contract, reproduced regression, phase gate or approved issue. Freeze scope and validation before changing it, and stop when the selected gates pass.
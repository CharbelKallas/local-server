# Local DevOps Lab

A local DevOps/cloud-native learning lab running on an Apple Silicon Mac (M2 Max, 32 GB RAM).

## Architecture Overview

| Component | Where it runs | Purpose |
|-----------|---------------|---------|
| **K3s** | Linux VM | Lightweight Kubernetes cluster |
| **Ollama** | Native macOS | Local LLM inference |
| **Docker** | Native macOS | Container runtime (used only where appropriate) |
| **LocalStack** | Docker | Local AWS service emulation |
| **Argo CD** | K3s | GitOps continuous delivery |
| **Kargo** | K3s | Progressive delivery |
| **Prometheus** | K3s | Metrics collection |
| **Grafana** | K3s | Observability dashboards |
| **Loki** | K3s | Log aggregation |

## Repository Structure

```
local-server/
├── README.md
├── Makefile
├── .gitignore
├── scripts/          # Automation and utility scripts
└── docs/             # Documentation
```

## Getting Started

This repository is a foundation. Components will be added incrementally.

Run `make help` to see available commands.

## Prerequisites

- Apple Silicon Mac (M2 Max, 32 GB RAM)
- [ ] Linux VM for K3s
- [ ] Docker Desktop or Colima
- [ ] Ollama
- [ ] LocalStack
- [ ] Argo CD
- [ ] Kargo
- [ ] Prometheus / Grafana / Loki

## License

MIT

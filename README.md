# Sovereign Data Platform (SDP)

**Cloud Agnostic | EU-First Compliance | 100% Open Source**

> **Status:** 🚧 Build-in-Progress | **Phase:** Core Infrastructure Setup  
> **Founder:** Dan Kjeldstrøm Hansen (Enterprise Data Architect)

---

## 1. Executive Summary

The SDP is a reference architecture for building **GDPR-compliant**, **cloud-agnostic**, and **fully sovereign** data platforms. Designed to eliminate vendor lock-in while providing robustness for enterprise-grade BI, ML, and AI workloads.

**Business Model:** Open Core — Free Community Edition for adoption; Enterprise Features (Advanced Security, Managed Services) for revenue.

---

## 2. Technical Architecture

### 2.1 Core Principles
- **Cloud Agnostic:** Runs on K3s, Standard K8s, Bare Metal, or EU-region Cloud.
- **EU-First Sovereignty:** Strict data residency enforcement; keys managed via self-hosted **OpenBao**.
- **Immutable Infrastructure:** Everything defined in **OpenTofu**; no manual server changes.
- **Functional Pipelines:** Pure functions (Input A → Output B) ensuring reproducibility.

### 2.2 Technology Stack

| Layer              | Technology                      | Role                                                |
|:------------------ |:------------------------------- |:--------------------------------------------------- |
| **Orchestration**  | Kubernetes (K3s / K8s)          | Container runtime & scheduling                      |
| **Storage**        | MinIO + Apache Iceberg          | S3-compatible object storage with ACID transactions |
| **Ingestion**      | **Apache NiFi** (+ Airbyte)     | Data logistics, routing, PII masking                |
| **Streaming**      | Redpanda / Kafka                | Real-time event processing                          |
| **Compute**        | Apache Spark / Trino            | Batch processing & Federated SQL                    |
| **Transformation** | dbt Core                        | SQL-based modeling & testing                        |
| **BI**             | Apache Superset                 | Visualization & Dashboards                          |
| **ML/AI**          | MLflow + Qdrant/Weaviate        | Model lifecycle & Vector DB for RAG                 |
| **Security**       | Keycloak + **OpenBao**          | IAM & Secrets Management (Vault Fork)               |
| **GitOps**         | ArgoCD                          | Declarative deployment sync                         |

### 2.3 Implementation Strategy
- **Infrastructure as Code:** Defined via **OpenTofu**.
- **Data Quality:** Embedded gates using Great Expectations & Soda Core.
- **Lineage:** Automated tracking via OpenLineage standards.

---

## 3. Roadmap & Next Steps

1.  ✅ **Phase 1:** Architecture Definition & Documentation (Current)
2.  ⏳ **Phase 2:** Bootstrap K3s Cluster & Core Services (MinIO, Keycloak, OpenBao)
3.  ⏳ **Phase 3:** Implement Ingestion Pipeline (NiFi → MinIO)
4.  ⏳ **Phase 4:** Add Compute Layer (Trino/Spark) & BI (Superset)
5.  ⏳ **Phase 5:** Hardening & Compliance Module Validation

---

## 4. Access & Contribution

📖 **[Architecture Overview](docs/architecture/architecture-overview.md)**  
🌐 **GitHub Repository:** [https://github.com/DanKHansen/SDP](https://github.com/DanKHansen/SDP)  

*Under active development. Contributions and feedback welcome!*
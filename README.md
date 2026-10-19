# ☸️ Orquestación & Observabilidad en Kubernetes — Visons S.A.C.

Infraestructura como código (IaC), manifiestos declarativos de Kubernetes, stack de observabilidad con **Prometheus Operator & Grafana**, políticas de autoescalado horizontal (**HPA**), y scripts de automatización para los microservicios de **Visons S.A.C.**

---

## 🏗️ Arquitectura de la Plataforma

```
                             [ Cliente / Navegador ]
                                        │
                                        ▼ (NodePort 30080 / Ingress)
                             ┌─────────────────────┐
                             │    frontend-web     │ (React + Vite)
                             └──────────┬──────────┘
                                        │
                    ┌───────────────────┴───────────────────┐
                    │                                       │
                    ▼ (NodePort 30090)                      ▼ (NodePort 30500)
       ┌─────────────────────────┐             ┌─────────────────────────┐
       │  backend-transaccional  │             │    backend-analitico    │
       │   Spring Boot WebFlux   │             │     Python 3.12 Flask   │
       │        (Java 25)        │             │    (Motor Analítico)    │
       └────────────┬────────────┘             └────────────┬────────────┘
                    │                                       │
           ┌────────┴────────┐                     ┌────────┴────────┐
           ▼                 ▼                     ▼                 ▼
    ┌─────────────┐   ┌─────────────┐       ┌─────────────┐   ┌─────────────┐
    │ SQL Server  │   │   MongoDB   │       │   MongoDB   │   │ SQL Server  │
    │  (Relacional│   │  (Atlas/    │       │ (Analytics) │   │ (Read Only) │
    │   ACID)     │   │   Cluster)  │       │             │   │             │
    └─────────────┘   └─────────────┘       └─────────────┘   └─────────────┘
                               ▲                           ▲
                               │                           │
                    ┌──────────┴───────────────────────────┴──────────┐
                    │         STACK DE OBSERVABILIDAD K8s             │
                    │  Prometheus Operator + Grafana + AlertManager   │
                    │      (ServiceMonitors, HPA Metrics & Alertas)   │
                    └─────────────────────────────────────────────────┘
```

---

## 📁 Estructura del Directorio `kubernetes/`

```text
kubernetes/
├── README.md                           # Este documento general
├── walkthrough.md                      # Guía del Expositor / Runbook de Presentación
├── k8s/                                # Manifiestos de Kubernetes
│   ├── 00-namespace.yaml               # Namespace visons-prod con label monitoring: enabled
│   ├── 01-secrets.yaml                 # Credenciales seguras (DBs, JWT)
│   ├── 02-configmaps.yaml              # Configuración desacoplada (URLs, Puertos)
│   ├── backend-transaccional/          # Spring Boot Java 25 (WebFlux)
│   │   ├── deployment.yaml             # Deployment con Probes y Resource Limits
│   │   ├── service.yaml                # Service NodePort 30090
│   │   └── hpa.yaml                    # Horizontal Pod Autoscaler (CPU 70%, Mem 80%)
│   ├── backend-analitico/              # Flask Python 3.12
│   │   ├── deployment.yaml             # Deployment con Probes y Limits
│   │   ├── service.yaml                # Service NodePort 30500
│   │   └── hpa.yaml                    # Horizontal Pod Autoscaler
│   ├── frontend-web/                   # Web React + Vite
│   │   ├── deployment.yaml             # Deployment UI
│   │   └── service.yaml                # Service NodePort 30080
│   ├── databases/                      # Persistencia Políglota In-Cluster (Opcional)
│   │   ├── sqlserver.yaml              # SQL Server 2022 PVC + Deployment + Service
│   │   └── mongodb.yaml                # MongoDB 7.0 PVC + Deployment + Service
│   ├── ingress/
│   │   └── ingress.yaml                # Reglas de enrutamiento NGINX Ingress
│   └── monitoring/                     # Observabilidad & Métricas
│       ├── prometheus-values.yaml      # Helm values de kube-prometheus-stack
│       ├── servicemonitor-backend.yaml # ServiceMonitor para /actuator/prometheus
│       ├── servicemonitor-backend-a.yaml # ServiceMonitor para /health
│       ├── alerting-rules.yaml         # Reglas de alerta para AlertManager
│       └── grafana-dashboard.json      # Dashboard exportado listo para importar
├── scripts/                            # Scripts de automatización
│   ├── setup.sh                        # Inicializador completo (1-click deploy)
│   ├── port-forward.sh                 # Gestor inteligente de túneles (WSL/Linux/macOS)
│   └── teardown.sh                     # Desinstalador limpio de recursos
├── load-testing/                       # Pruebas de estrés y resiliencia
│   ├── stress-test.sh                  # Disparador de tormentas de carga para HPA
│   └── chaos-simulation.sh             # Prueba de autoreparación (Self-Healing) y alertas
└── docs/                               # Documentación técnica extendida
    ├── 01-arquitectura-cluster.md      # Diseño de red, storage y ciclo de vida de pods
    └── 02-monitoreo-observabilidad.md  # Diccionario de métricas y consultas PromQL
```

---

## ⚡ Guía de Inicio Rápido (Quickstart)

### 1. Despliegue de Todo el Entorno (Setup Automático)
```bash
# Ejecutar desde la raíz de este directorio
bash scripts/setup.sh
```
El script automáticamente:
- Verifica herramientas (`docker`, `minikube`, `kubectl`, `helm`).
- Inicia Minikube habilitando `metrics-server` e `ingress`.
- Aplica Namespaces, Secrets y ConfigMaps.
- Instala el stack de Observabilidad con Helm (`kube-prometheus-stack`).
- Despliega las bases de datos y los microservicios.
- Configura los `ServiceMonitors` y reglas de alerta.
- Sincroniza el Dashboard Ejecutivo en Grafana.

---

### 2. Abrir Puertos para Navegación Local
```bash
bash scripts/port-forward.sh
```

| Servicio | URL Local | Credenciales |
|---|---|---|
| 📊 **Grafana** | `http://localhost:3000` | `admin` / `visons2026` |
| 🔥 **Prometheus** | `http://localhost:9091` | *Público* |
| ☕ **Backend Transaccional** | `http://localhost:9090/actuator/health` | *API Core* |
| 🐍 **Backend Analítico** | `http://localhost:5000/health` | *Analytics API* |
| 🌐 **Frontend Web** | `http://localhost:8080` | *Web Portal* |

---

### 3. Ejecutar Pruebas de Carga y Autoescalado (HPA)
```bash
# Simular tormenta de requests concurrentes para activar el HPA
bash load-testing/stress-test.sh storm 600

# En otra terminal, observar cómo escala en vivo de 1 a 5 pods:
kubectl get hpa -n visons-prod --watch
```

---

### 4. Simulación de Caos y Recuperación (Self-Healing)
```bash
# Probar la capacidad de autoreparación ante la caída de un pod
bash load-testing/chaos-simulation.sh healing

# Probar el disparo de alertas en AlertManager
bash load-testing/chaos-simulation.sh alert
```

---

### 5. Limpieza del Clúster
```bash
bash scripts/teardown.sh
```

---

## 📖 Guía de Presentación

Para la secuencia paso a paso durante exposiciones, revisiones o defensas académicas, consulta:
👉 **[walkthrough.md](file:///home/diego/Documentos/UN1/FN1/kubernetes/walkthrough.md)**

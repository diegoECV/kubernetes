# 🎓 Guía del Expositor — Secuencia de Presentación: Visons S.A.C.

> **Runbook Oficial de Evaluación / Presentación Técnica**  
> Ten este documento abierto en una pantalla secundaria mientras defiendes la arquitectura de microservicios, el autoescalado y el sistema de observabilidad.

---

## ⏱️ ANTES DE INICIAR LA PRESENTACIÓN (10 min antes)

### 1. Terminal 1 — Iniciar el entorno y verificar el clúster

```bash
# Navegar a la carpeta de Kubernetes en FN1
cd /home/diego/Documentos/UN1/FN1/kubernetes

# Verificar estado de Minikube
minikube status

# Si no está corriendo o es la primera vez:
bash scripts/setup.sh
```

### 2. Verificar que los Pods estén en estado `Running`

```bash
# Pods de la plataforma Visons S.A.C.
kubectl get pods -n visons-prod -o wide
# Debe mostrar:
# backend-transaccional-xxx    1/1     Running   0
# backend-analitico-xxx        1/1     Running   0
# frontend-web-xxx             1/1     Running   0
# sqlserver-xxx                1/1     Running   0
# mongodb-xxx                  1/1     Running   0

# Pods del stack de Monitoreo
kubectl get pods -n monitoring
# monitoring-grafana-xxx       3/3     Running   0
# prometheus-xxx               2/2     Running   0
# alertmanager-xxx             2/2     Running   0
```

### 3. Terminal 2 — Iniciar los túneles Port-Forward (déjala abierta)

```bash
bash scripts/port-forward.sh
```

---

## 🌐 URLs de Acceso para la Demostración

| Servicio | URL Local | Credenciales / Endpoint | Propósito en la Demo |
|---|---|---|---|
| 📊 **Grafana** | `http://localhost:3000` | `admin` / `visons2026` | Dashboard ejecutivo de métricas y rendimiento |
| 🔥 **Prometheus** | `http://localhost:9091` | *Sin autenticación* | Consulta de métricas en tiempo real con PromQL |
| ☕ **Backend Transaccional** | `http://localhost:9090` | `/actuator/health` | API Reactiva no bloqueante en Spring Boot / Java 25 |
| 🐍 **Backend Analítico** | `http://localhost:5000` | `/health` / `/api/v1/analytics/...` | Motor analítico en Python 3.12 Flask |
| 🌐 **Frontend Web** | `http://localhost:8080` | *Portal Web* | Interfaz de usuario React + Vite |

---

## 🚀 SECUENCIA DE LA EXPOSICIÓN (Paso a Paso)

### 📌 MÓDULO 1 — Visión General & Arquitectura (5 min)

**Qué mostrar en pantalla:**
1. Abre el navegador en `http://localhost:3000` (Grafana) y muestra el dashboard: **"🏢 Visons S.A.C. — Observabilidad & Microservicios"**.
2. Abre la consola para mostrar los objetos de Kubernetes:
   ```bash
   kubectl get all -n visons-prod
   ```

**Lo que dices al jurado / profesor:**
> *"Nuestra solución para Visons S.A.C. implementa una arquitectura de microservicios contenerizada sobre Kubernetes con persistencia políglota y observabilidad de nivel empresarial. Contamos con un backend transaccional de alto rendimiento en Java 25 WebFlux, un motor analítico en Python Flask, bases de datos relacionales y NoSQL, y un frontend desacoplado. Todo está orquestado mediante Deployments, Services con descubrimiento DNS, políticas de autoescalado HPA y sondas de salud automáticas."*

---

### 📌 MÓDULO 2 — Despliegue & Manifiestos de Kubernetes (10 min)

**Qué mostrar en pantalla:**
1. Los archivos de manifiestos en `k8s/`:
   - `00-namespace.yaml`: Destacar la etiqueta `monitoring: "enabled"`.
   - `01-secrets.yaml` & `02-configmaps.yaml`: Mostrar cómo se desacoplan las variables sensibles del contenedor.
   - `backend-transaccional/deployment.yaml`: Destacar:
     - Sondas `livenessProbe` y `readinessProbe` apuntando a `/actuator/health`.
     - Definición de `resources.requests` y `resources.limits`.
     - Estrategia `RollingUpdate` para despliegues con cero tiempo de inactividad (Zero Downtime).

**Comandos para ejecutar en vivo:**
```bash
# Inspeccionar las sondas y límites configurados
kubectl describe deployment backend-transaccional -n visons-prod

# Validar la resolución de nombres DNS interna entre pods
kubectl exec -it deploy/backend-analitico -n visons-prod -- ping -c 2 sqlserver-service
```

---

### 📌 MÓDULO 3 — Observabilidad con Prometheus & ServiceMonitors (10 min)

**Qué mostrar en pantalla:**
1. Abrir `http://localhost:9091/targets` en Prometheus:
   - Mostrar cómo Prometheus descubre automáticamente los endpoints gracias al operador:
     - `backend-transaccional-service` ➜ `http://10.x.x.x:9090/actuator/prometheus` (Estado: **UP ✅**)
     - `backend-analitico-service` ➜ `http://10.x.x.x:5000/health` (Estado: **UP ✅**)
2. Ir a la pestaña **Graph** en Prometheus (`http://localhost:9091/graph`) y ejecutar estas consultas PromQL en vivo:

```promql
# 1. Comprobar que todos los servicios de la plataforma están vivos
up{namespace="visons-prod"}

# 2. Medir la memoria Heap de la máquina virtual Java 25
jvm_memory_used_bytes{area="heap", application="backend-transaccional"}

# 3. Consultar la tasa de peticiones HTTP en tiempo real
sum(rate(http_server_requests_seconds_count[1m])) by (uri)
```

**Punto clave para explicar:**
> *"No usamos agentes pesados de terceros. El microservicio de Spring Boot expone sus métricas mediante Micrometer en formato Prometheus nativo. El Prometheus Operator se encarga del scrape periódico de forma completamente declarativa a través del Custom Resource Definition (CRD) `ServiceMonitor`."*

---

### 📌 MÓDULO 4 — Demostración de Autoescalado Horizontal (HPA) (10 min)

**Esta es la casuística estrella de la presentación.**

**Paso 1:** Muestra el panel de HPA antes de la carga:
```bash
kubectl get hpa -n visons-prod
# REPLICAS: 1, TARGETS: 0%/70%
```

**Paso 2:** En una nueva terminal, lanza la tormenta de peticiones:
```bash
bash load-testing/stress-test.sh storm 600
```

**Paso 3:** Observa en tiempo real en Grafana y en la terminal:
```bash
# Observar en vivo cómo escala
kubectl get hpa -n visons-prod --watch
```
- El consumo de CPU supera el 70%.
- El controlador de Kubernetes crea automáticamente réplicas adicionales (de 1 pod escala a 2, 3 o más).
- En Grafana, el panel **"🔢 Réplicas HPA — backend-transaccional"** registra la curva ascendente.
- El tiempo de respuesta de la plataforma se mantiene estable gracias a la distribución de carga.

---

### 📌 MÓDULO 5 — Resiliencia y Auto-Recuperación (Self-Healing) (5 min)

**Paso 1:** Simular la muerte accidental de un pod de producción:
```bash
bash load-testing/chaos-simulation.sh healing
```

**Lo que demuestras:**
> *"Cuando un pod falla o el proceso muere de forma imprevista, el ReplicaSet de Kubernetes detecta que el estado actual difiere del estado deseado y crea un nuevo pod sano en menos de 2 segundos, garantizando alta disponibilidad sin intervención humana."*

**Paso 2:** Mostrar la gestión de incidentes en AlertManager:
```bash
# Abrir las reglas de alerta configuradas
kubectl get prometheusrules -n visons-prod
```
- Visita `http://localhost:9091/alerts` para ver las alertas activas:
  - `BackendTransaccionalDown`
  - `PodHighMemoryUsage`
  - `HighHttp5xxRate`

---

## 🏁 CONCLUSIONES PARA CERRAR LA PRESENTACIÓN

1. **Aislamiento y Escalabilidad:** Microservicios desacoplados con límites garantizados que no comprometen la estabilidad del nodo.
2. **Observabilidad Integral:** Métricas en tiempo real que permiten pasar de un monitoreo reactivo a un monitoreo proactivo antes de que el usuario final perciba fallas.
3. **Resiliencia Automática:** Kubernetes gestiona el ciclo de vida, la tolerancia a fallos y el autoescalado dinámico según la demanda del negocio.

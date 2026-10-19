# 📊 Guía de Monitoreo & Observabilidad — Visons S.A.C.

## 1. Stack Tecnológico de Observabilidad
- **Prometheus Operator**: Automatiza el ciclo de vida del clúster de Prometheus usando Custom Resource Definitions (CRDs).
- **Prometheus Server**: Base de datos de series temporales con raspado pull a intervalos de 15 segundos.
- **Grafana 10+**: Visualización ejecutiva y operativa con datasource aprovisionado automáticamente.
- **AlertManager**: Agrupación y enrutamiento de alertas críticas y de advertencia.
- **kube-state-metrics & node-exporter**: Métricas a nivel de sistema operativo y del plano de control de Kubernetes.

---

## 2. Definiciones de ServiceMonitor

El archivo [servicemonitor-backend.yaml](file:///home/diego/Documentos/UN1/FN1/kubernetes/k8s/monitoring/servicemonitor-backend.yaml) le indica a Prometheus cómo raspar las métricas de Spring Boot:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: backend-transaccional-monitor
  namespace: visons-prod
  labels:
    app: backend-transaccional
    monitoring: "enabled"
spec:
  selector:
    matchLabels:
      app: backend-transaccional
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
```

---

## 3. Consultas PromQL Esenciales para Demostraciones

### Disponibilidad de Servicios (Up / Down)
```promql
# Devuelve 1 para pods saludables, 0 para caídos
up{namespace="visons-prod"}
```

### Tasa de Peticiones por Segundo (Throughput)
```promql
sum(rate(http_server_requests_seconds_count[1m])) by (uri)
```

### Latencia Percentil 95 (SLA)
```promql
histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket[1m])) by (le))
```

### Memoria Heap de la Máquina Virtual Java 25
```promql
jvm_memory_used_bytes{area="heap", application="backend-transaccional"}
```

### Consumo de CPU de Contenedores vs Límites
```promql
sum(rate(container_cpu_usage_seconds_total{namespace="visons-prod", container!=""}[1m])) by (pod) 
/ 
sum(kube_pod_container_resource_limits{namespace="visons-prod", resource="cpu"}) by (pod)
```

---

## 4. Reglas de Alerta (PrometheusRule)

Las reglas en [alerting-rules.yaml](file:///home/diego/Documentos/UN1/FN1/kubernetes/k8s/monitoring/alerting-rules.yaml) vigilan los siguientes umbrales:
1. **`BackendTransaccionalDown`**: Dispara si el servicio transaccional no responde durante más de 30 segundos.
2. **`BackendAnaliticoDown`**: Dispara si el servicio analítico se encuentra inaccesible.
3. **`HighHttp5xxRate`**: Alerta si más del 5% de las solicitudes devuelven códigos de error 500 en una ventana de 3 minutos.
4. **`PodCrashLoopBackOff`**: Detecta pods atrapados en fallas recurrentes de arranque.
5. **`PodHighMemoryUsage`**: Previene caídas por OOMKilled cuando el uso de memoria rebasa el 85% del límite asignado.

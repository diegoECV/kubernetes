# 🏛️ Arquitectura del Clúster Kubernetes — Visons S.A.C.

## 1. Resumen Ejecutivo
La plataforma empresarial de **Visons S.A.C.** está diseñada bajo un modelo de **microservicios desacoplados** que operan sobre Kubernetes para garantizar elasticidad, observabilidad continua, tolerancia a fallos y despliegues sin interrupción de servicio (Zero Downtime).

---

## 2. Componentes del Clúster

### A. Namespace (`visons-prod`)
Aislamiento lógico de recursos para producción.
- **Label Crítico**: `monitoring: "enabled"`. Este selector es utilizado por el **Prometheus Operator** para auto-descubrir los `ServiceMonitors` y `PrometheusRules`.

### B. Microservicios

1. **Backend Transaccional (`backend-transaccional`)**:
   - **Tecnología**: Spring Boot WebFlux 3.x sobre Java 25.
   - **Patrón**: Arquitectura reactiva no bloqueante basada en Project Reactor y Netty.
   - **Exposición**: Service NodePort en puerto `30090` (puerto interno `9090`).
   - **Métricas**: `/actuator/prometheus` mediante Micrometer.
   - **Health Checks**: `/actuator/health` con comprobación de liveness y readiness.
   - **Autoescalado**: HPA configurado entre 1 y 5 réplicas con umbrales de CPU al 70% y memoria al 80%.

2. **Backend Analítico (`backend-analitico`)**:
   - **Tecnología**: Python 3.12, Flask, Gunicorn, PyMongo, PyMSSQL.
   - **Patrón**: API REST para analítica predictiva, reportes de calidad, KPIs y métricas de inventario.
   - **Exposición**: Service NodePort en puerto `30500` (puerto interno `5000`).
   - **Health Checks**: `/health`.

3. **Frontend Web (`frontend-web`)**:
   - **Tecnología**: React, Vite, TypeScript, TailwindCSS.
   - **Exposición**: Service NodePort en puerto `30080` (puerto interno `80`).

---

## 3. Persistencia Políglota

La solución admite dos modalidades de persistencia:

### Modalidad Híbrida / Cloud (Por defecto en producción)
- **SQL Server**: Instancia gestionada en AWS RDS (`visons-db.cjwoansjw85b.us-east-1.rds.amazonaws.com:1433`).
- **MongoDB**: Clúster gestionado en MongoDB Atlas (`cluster0.1qojbcp.mongodb.net`).
- **Configuración**: Inyectada de forma segura vía `visons-secrets` y `visons-config`.

### Modalidad In-Cluster (Para entornos aislados y pruebas)
- Manifiestos listos en `k8s/databases/`:
  - `sqlserver.yaml`: SQL Server 2022 con PersistentVolumeClaim de 5GB.
  - `mongodb.yaml`: MongoDB 7.0 con PersistentVolumeClaim de 5GB.

---

## 4. Estrategia de Despliegue (Zero Downtime)
Todos los deployments utilizan la estrategia `RollingUpdate`:
- `maxSurge: 1`: Durante una actualización, Kubernetes levantará un pod nuevo antes de destruir el pod antiguo.
- `maxUnavailable: 0`: Garantiza que en ningún momento la cantidad de pods disponibles caiga a cero.
- Las sondas `readinessProbe` previenen que el tráfico del Service sea dirigido al nuevo pod hasta que haya completado su inicialización interna.

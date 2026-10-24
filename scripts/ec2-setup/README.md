# 🚀 Guía de Configuración EC2 — Visons S.A.C.

## Orden de ejecución

```
EC2 #1 MASTER  →  EC2 #2 Frontend  →  EC2 #3 Backend-T  →  EC2 #4 Backend-A  →  EC2 #5 MongoDB
```

---

## ☁️ Resumen de instancias EC2

| # | Script | Tags AWS | Tipo EC2 | Storage | Puertos (inbound) |
|---|--------|----------|----------|---------|------------------|
| 1 | `EC2-1-MASTER.sh` | `Name=visons-master` `Role=control-plane` | **t3.medium** | 20 GB | 22, 6443, 30080-30500 |
| 2 | `EC2-2-WORKER-FRONTEND.sh` | `Name=visons-worker-frontend` `Role=worker-frontend` | **t3.small** | 10 GB | 22, 80, 30080 |
| 3 | `EC2-3-WORKER-BACKEND-TRANSACCIONAL.sh` | `Name=visons-worker-backend1` `Role=worker-backend-transaccional` | **t3.medium** | 15 GB | 22, 30090 |
| 4 | `EC2-4-WORKER-BACKEND-ANALITICO.sh` | `Name=visons-worker-backend2` `Role=worker-backend-analitico` | **t3.medium** | 20 GB | 22, 30500 |
| 5 | `EC2-5-WORKER-MONGODB.sh` | `Name=visons-worker-mongodb` `Role=worker-database-mongo` `DB=mongodb` | **t3.medium** | 20 GB | 22, 27017 (solo VPC) |

---

## 📋 Paso a Paso

### 1. EC2 #1 — Inicializar el Master
```bash
scp -i visons-key.pem EC2-1-MASTER.sh ubuntu@<IP_MASTER>:~/
ssh -i visons-key.pem ubuntu@<IP_MASTER>
sudo bash EC2-1-MASTER.sh
# ⚠️ Guarda el "kubeadm join ..." que aparece al final
```

### 2. Copiar kubeconfig a tu máquina local
```bash
scp -i visons-key.pem ubuntu@<IP_MASTER>:/home/ubuntu/.kube/config ~/.kube/visons-config
export KUBECONFIG=~/.kube/visons-config
kubectl get nodes
```

### 3. EC2 #2 — Worker Frontend
```bash
scp -i visons-key.pem EC2-2-WORKER-FRONTEND.sh ubuntu@<IP_W2>:~/
ssh -i visons-key.pem ubuntu@<IP_W2>
sudo bash EC2-2-WORKER-FRONTEND.sh "kubeadm join <IP_PRIVADA>:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
```

### 4. EC2 #3 — Worker Backend Transaccional
```bash
scp -i visons-key.pem EC2-3-WORKER-BACKEND-TRANSACCIONAL.sh ubuntu@<IP_W3>:~/
ssh -i visons-key.pem ubuntu@<IP_W3>
sudo bash EC2-3-WORKER-BACKEND-TRANSACCIONAL.sh "kubeadm join ..."
```

### 5. EC2 #4 — Worker Backend Analítico
```bash
scp -i visons-key.pem EC2-4-WORKER-BACKEND-ANALITICO.sh ubuntu@<IP_W4>:~/
ssh -i visons-key.pem ubuntu@<IP_W4>
sudo bash EC2-4-WORKER-BACKEND-ANALITICO.sh "kubeadm join ..."
```

### 6. EC2 #5 — Worker MongoDB
```bash
scp -i visons-key.pem EC2-5-WORKER-MONGODB.sh ubuntu@<IP_W5>:~/
ssh -i visons-key.pem ubuntu@<IP_W5>
sudo bash EC2-5-WORKER-MONGODB.sh "kubeadm join ..."
```

### 7. Desplegar todo desde tu máquina local
```bash
cd kubernetes/
bash scripts/deploy-master.sh <IP_PUBLICA_MASTER>
```

---

## 🌐 URLs finales (reemplaza con tu IP del Master)

| Servicio | URL |
|----------|-----|
| Frontend Web | `http://<IP_MASTER>:30080` |
| Backend Transaccional | `http://<IP_MASTER>:30090/api/v1` |
| Backend Analítico | `http://<IP_MASTER>:30500/api/v1/analytics` |
| Grafana | `http://<IP_MASTER>:30300` |
| Prometheus | `http://<IP_MASTER>:30091` |

## 🛢 Bases de Datos (acceso SOLO interno del clúster)

| DB | DNS Kubernetes | Puerto |
|----|---------------|--------|
| MongoDB 7.0 | `mongodb-service.visons-prod.svc.cluster.local` | 27017 |
| SQL Server 2022 | `sqlserver-service.visons-prod.svc.cluster.local` | 1433 |

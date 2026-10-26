-- =====================================================================
-- Visons_sqlserver_completo.sql
-- Script COMPLETO e IDEMPOTENTE de SQL Server para VISONS S.A.C.
-- Contiene las 11 tablas del negocio + 1 tabla de control (V001..V004)
-- con exactamente 10 datos semilla por entidad y limpieza previa
-- para ejecutarse cuantas veces sea necesario SIN ERRORES.
-- =====================================================================

USE master;
GO

IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'Visons')
BEGIN
  CREATE DATABASE Visons;
END;
GO

USE Visons;
GO

-- 1. Esquema de control de versiones
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'control')
BEGIN
  EXEC('CREATE SCHEMA control AUTHORIZATION dbo;');
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'control.schema_change') AND type in (N'U'))
BEGIN
  CREATE TABLE control.schema_change (
    sequence        INT           NOT NULL PRIMARY KEY,
    change_id       NVARCHAR(120) NOT NULL UNIQUE,
    checksum        NVARCHAR(64)  NOT NULL,
    git_sha         NVARCHAR(40)  NOT NULL,
    release_version NVARCHAR(30)  NOT NULL,
    applied_at      DATETIME2     NOT NULL DEFAULT SYSDATETIME()
  );
END;
GO

-- 2. Creación de las 11 Tablas del Negocio si no existen

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'ORDERS') AND type in (N'U'))
BEGIN
  CREATE TABLE ORDERS (
    order_id                INT IDENTITY(1,1) PRIMARY KEY,
    client_id               VARCHAR(255)  NOT NULL,
    order_code              NVARCHAR(50)  NULL UNIQUE,
    order_date              DATE          NOT NULL DEFAULT GETDATE(),
    incoterm                CHAR(3)       NULL,
    status                  NVARCHAR(50)  NULL,
    status_description      NVARCHAR(255) NULL,
    currency                VARCHAR(10)   NULL,
    payment_terms           VARCHAR(255)  NULL,
    destination_port        VARCHAR(255)  NULL,
    estimated_shipping_date DATE          NULL
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'ORDER_DETAILS') AND type in (N'U'))
BEGIN
  CREATE TABLE ORDER_DETAILS (
    order_detail_id INT IDENTITY(1,1) PRIMARY KEY,
    order_id        INT             NOT NULL,
    product_id      VARCHAR(255)    NOT NULL,
    batch_id        VARCHAR(255)    NULL,
    quantity_kg     DECIMAL(18,3)   NOT NULL,
    unit_price      DECIMAL(18,4)   NOT NULL,
    quantity_boxes  INT             NULL,
    total_price     DECIMAL(18,4)   NULL
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'AUDIT_LOGS') AND type in (N'U'))
BEGIN
  CREATE TABLE AUDIT_LOGS (
    id              BIGINT IDENTITY(1,1) PRIMARY KEY,
    user_id         VARCHAR(255),
    username        VARCHAR(255),
    action          VARCHAR(50),
    resource        VARCHAR(100),
    resource_id     VARCHAR(255),
    timestamp       DATETIME2,
    changes_before  NVARCHAR(MAX),
    changes_after   NVARCHAR(MAX),
    ip_address      VARCHAR(100)
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'PAYMENTS') AND type in (N'U'))
BEGIN
  CREATE TABLE PAYMENTS (
    payment_id      INT IDENTITY(1,1) PRIMARY KEY,
    order_id        INT,
    amount          DECIMAL(18,2),
    payment_date    DATETIME2,
    payment_method  VARCHAR(50),
    reference_code  VARCHAR(100),
    notes           NVARCHAR(MAX)
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'INVOICES') AND type in (N'U'))
BEGIN
  CREATE TABLE INVOICES (
    invoice_id       INT IDENTITY(1,1) PRIMARY KEY,
    order_id         INT,
    invoice_number   VARCHAR(100),
    issue_date       DATETIME2,
    due_date         DATETIME2,
    currency         VARCHAR(10),
    subtotal         DECIMAL(18,2),
    taxes            DECIMAL(18,2),
    total            DECIMAL(18,2),
    status           VARCHAR(50),
    document_type    VARCHAR(50)   NULL,
    exchange_rate    DECIMAL(10,4) NULL,
    sunat_cdr_status VARCHAR(50)   NULL
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'SHIPMENTS') AND type in (N'U'))
BEGIN
  CREATE TABLE SHIPMENTS (
    shipment_id          INT IDENTITY(1,1) PRIMARY KEY,
    order_id             INT,
    bl_number            VARCHAR(100),
    booking_number       VARCHAR(100) NULL,
    freight_forwarder    VARCHAR(255) NULL,
    vessel_name          VARCHAR(255),
    container_number     VARCHAR(100),
    departure_port       VARCHAR(255),
    arrival_port         VARCHAR(255),
    departure_date       DATETIME2,
    estimated_arrival    DATETIME2,
    status               VARCHAR(50),
    temperature_setpoint DECIMAL(5,2)
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID(N'SHIPMENTS') AND name = 'booking_number')
BEGIN
  ALTER TABLE SHIPMENTS ADD booking_number VARCHAR(100) NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.columns WHERE object_id = OBJECT_ID(N'SHIPMENTS') AND name = 'freight_forwarder')
BEGIN
  ALTER TABLE SHIPMENTS ADD freight_forwarder VARCHAR(255) NULL;
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'SHIPMENT_ITEMS') AND type in (N'U'))
BEGIN
  CREATE TABLE SHIPMENT_ITEMS (
    item_id          INT IDENTITY(1,1) PRIMARY KEY,
    shipment_id      INT,
    product_id       VARCHAR(255),
    quantity_pallets INT,
    quantity_boxes   INT,
    net_weight_kg    DECIMAL(18,2),
    gross_weight_kg  DECIMAL(18,2)
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'CERTIFICATES') AND type in (N'U'))
BEGIN
  CREATE TABLE CERTIFICATES (
    certificate_id      INT IDENTITY(1,1) PRIMARY KEY,
    shipment_id         INT,
    batch_id            VARCHAR(255),
    type                VARCHAR(100),
    issued_by           VARCHAR(255),
    issue_date          DATETIME2,
    expiry_date         DATETIME2,
    certificate_number  VARCHAR(100),
    file_url            NVARCHAR(MAX)
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'CUSTOMS_DECLARATIONS') AND type in (N'U'))
BEGIN
  CREATE TABLE CUSTOMS_DECLARATIONS (
    declaration_id  INT IDENTITY(1,1) PRIMARY KEY,
    shipment_id     INT,
    dam_number      VARCHAR(100),
    fob_value       DECIMAL(18,2),
    customs_agency  VARCHAR(255),
    filing_date     DATETIME2,
    status          VARCHAR(50)
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'ASSIGNMENTS') AND type in (N'U'))
BEGIN
  CREATE TABLE ASSIGNMENTS (
    assignment_id   INT IDENTITY(1,1) PRIMARY KEY,
    order_id        INT NOT NULL,
    assignment_type VARCHAR(100),
    assigned_to     VARCHAR(255),
    assigned_by     VARCHAR(255),
    priority        VARCHAR(50),
    status          VARCHAR(50),
    notes           NVARCHAR(MAX),
    assignment_date DATE,
    due_date        DATE,
    completion_date DATE
  );
END;
GO

IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'BATCHES') AND type in (N'U'))
BEGIN
  CREATE TABLE BATCHES (
    batch_id        INT IDENTITY(1,1) PRIMARY KEY,
    product_code    VARCHAR(255),
    provider_id     VARCHAR(255),
    field_name      VARCHAR(255),
    harvest_date    DATE,
    packing_date    DATE,
    production_date DATE,
    expiration_date DATE
  );
END;
GO

-- 3. Llaves Foráneas (solo si no existen)
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_od_order')
  ALTER TABLE ORDER_DETAILS ADD CONSTRAINT FK_od_order FOREIGN KEY (order_id) REFERENCES ORDERS (order_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_pay_order')
  ALTER TABLE PAYMENTS ADD CONSTRAINT FK_pay_order FOREIGN KEY (order_id) REFERENCES ORDERS (order_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_inv_order')
  ALTER TABLE INVOICES ADD CONSTRAINT FK_inv_order FOREIGN KEY (order_id) REFERENCES ORDERS (order_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_ship_order')
  ALTER TABLE SHIPMENTS ADD CONSTRAINT FK_ship_order FOREIGN KEY (order_id) REFERENCES ORDERS (order_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_si_ship')
  ALTER TABLE SHIPMENT_ITEMS ADD CONSTRAINT FK_si_ship FOREIGN KEY (shipment_id) REFERENCES SHIPMENTS (shipment_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_cert_ship')
  ALTER TABLE CERTIFICATES ADD CONSTRAINT FK_cert_ship FOREIGN KEY (shipment_id) REFERENCES SHIPMENTS (shipment_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_cd_ship')
  ALTER TABLE CUSTOMS_DECLARATIONS ADD CONSTRAINT FK_cd_ship FOREIGN KEY (shipment_id) REFERENCES SHIPMENTS (shipment_id);
IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_assignment_order')
  ALTER TABLE ASSIGNMENTS ADD CONSTRAINT FK_assignment_order FOREIGN KEY (order_id) REFERENCES ORDERS (order_id);
GO

-- 4. LIMPIEZA TOTAL PARA GARANTIZAR IDEMPOTENCIA (Sin errores de llave duplicada)
PRINT 'Limpiando tablas para reinsercion limpia...';
GO

DELETE FROM CUSTOMS_DECLARATIONS;
DELETE FROM CERTIFICATES;
DELETE FROM SHIPMENT_ITEMS;
DELETE FROM SHIPMENTS;
DELETE FROM INVOICES;
DELETE FROM PAYMENTS;
DELETE FROM ORDER_DETAILS;
DELETE FROM ASSIGNMENTS;
DELETE FROM ORDERS;
DELETE FROM AUDIT_LOGS;
DELETE FROM BATCHES;
DELETE FROM control.schema_change;
GO

DBCC CHECKIDENT ('ORDERS', RESEED, 0);
DBCC CHECKIDENT ('ORDER_DETAILS', RESEED, 0);
DBCC CHECKIDENT ('PAYMENTS', RESEED, 0);
DBCC CHECKIDENT ('INVOICES', RESEED, 0);
DBCC CHECKIDENT ('SHIPMENTS', RESEED, 0);
DBCC CHECKIDENT ('SHIPMENT_ITEMS', RESEED, 0);
DBCC CHECKIDENT ('CERTIFICATES', RESEED, 0);
DBCC CHECKIDENT ('CUSTOMS_DECLARATIONS', RESEED, 0);
DBCC CHECKIDENT ('AUDIT_LOGS', RESEED, 0);
DBCC CHECKIDENT ('ASSIGNMENTS', RESEED, 0);
DBCC CHECKIDENT ('BATCHES', RESEED, 0);
GO

-- 5. Inserción de Semillas Coherentes (10 filas por entidad)
PRINT 'Insertando 10 datos semilla por cada entidad en SQL Server...';
GO

-- 1. ORDERS (10 filas)
INSERT INTO ORDERS (client_id, order_code, order_date, incoterm, status, status_description, currency, payment_terms, destination_port, estimated_shipping_date) VALUES
('CLI-001', 'ORD-001', '2026-09-01', 'FOB', 'COMPLETED', 'Completado con exito', 'USD', '30 dias', 'Rotterdam', '2026-09-15'),
('CLI-002', 'ORD-002', '2026-09-02', 'CIF', 'COMPLETED', 'Completado y pagado', 'USD', 'Contado', 'Hamburg', '2026-09-16'),
('CLI-003', 'ORD-003', '2026-09-03', 'EXW', 'COMPLETED', 'Retirado en planta', 'EUR', '60 dias', 'Valencia', '2026-09-17'),
('CLI-004', 'ORD-004', '2026-09-04', 'FOB', 'PENDING',   'En espera de confirmacion', 'USD', '30 dias', 'Long Beach', '2026-09-20'),
('CLI-005', 'ORD-005', '2026-09-05', 'CIF', 'PENDING',   'Pendiente de asignacion', 'USD', 'Contado', 'Miami', '2026-09-21'),
('CLI-006', 'ORD-006', '2026-09-06', 'FCA', 'SHIPPED',   'Cargamento en transito', 'USD', '45 dias', 'Yokohama', '2026-09-22'),
('CLI-007', 'ORD-007', '2026-09-07', 'FOB', 'SHIPPED',   'En ruta maritima', 'EUR', '30 dias', 'Antwerp', '2026-09-23'),
('CLI-008', 'ORD-008', '2026-09-08', 'CIF', 'DELIVERED', 'Entregado en destino', 'USD', 'Contado', 'Busan', '2026-09-25'),
('CLI-009', 'ORD-009', '2026-09-09', 'EXW', 'PROCESSING','En empaque y pesado', 'USD', '30 dias', 'Callao', '2026-09-26'),
('CLI-010', 'ORD-010', '2026-09-10', 'FOB', 'PROCESSING','En control de calidad', 'USD', 'Contado', 'Shanghai', '2026-09-27');
GO

-- 2. ORDER_DETAILS (10 filas)
INSERT INTO ORDER_DETAILS (order_id, product_id, batch_id, quantity_kg, unit_price, quantity_boxes, total_price) VALUES
(1, 'PROD-001', 'BATCH-001', 500.00,  2.50, 50,  1250.00),
(2, 'PROD-002', 'BATCH-002', 1000.00, 3.20, 100, 3200.00),
(3, 'PROD-003', 'BATCH-003', 750.00,  1.80, 75,  1350.00),
(4, 'PROD-004', 'BATCH-004', 1200.00, 2.45, 120, 2940.00),
(5, 'PROD-005', 'BATCH-005', 800.00,  3.15, 80,  2520.00),
(6, 'PROD-006', 'BATCH-006', 2000.00, 4.00, 200, 8000.00),
(7, 'PROD-007', 'BATCH-007', 300.00,  2.60, 30,  780.00),
(8, 'PROD-008', 'BATCH-008', 600.00,  1.90, 60,  1140.00),
(9, 'PROD-009', 'BATCH-009', 1500.00, 3.10, 150, 4650.00),
(10,'PROD-010', 'BATCH-010', 2500.00, 3.90, 250, 9750.00);
GO

-- 3. AUDIT_LOGS (10 filas)
INSERT INTO AUDIT_LOGS (user_id, username, action, resource, resource_id, timestamp, ip_address) VALUES
('U-001', 'Admin Visons', 'LOGIN',  'System',    NULL,       '2026-09-18T08:00:00', '192.168.1.10'),
('U-002', 'Diego Centeno', 'CREATE', 'Order',     '1',        '2026-09-18T08:15:22', '192.168.1.12'),
('U-003', 'Lizeth Quispe', 'UPDATE', 'Inventory', 'PROD-001', '2026-09-18T09:30:10', '192.168.1.15'),
('U-004', 'Operador 1',    'DELETE', 'User',      'U-011',    '2026-09-18T10:05:00', '192.168.1.10'),
('U-005', 'Supervisor',    'UPDATE', 'Order',     '2',        '2026-09-18T11:20:00', '192.168.1.12'),
('U-006', 'Logistica',     'CREATE', 'Shipment',  '1',        '2026-09-18T13:45:00', '192.168.1.15'),
('U-007', 'Admin Visons', 'UPDATE', 'Role',      'R-02',     '2026-09-18T14:10:00', '192.168.1.10'),
('U-008', 'Auditor Int',   'LOGIN',  'System',    NULL,       '2026-09-18T15:00:00', '192.168.1.12'),
('U-009', 'Facturacion',   'UPDATE', 'Invoice',   '1',        '2026-09-18T16:30:00', '192.168.1.15'),
('U-010', 'Admin Visons', 'LOGOUT', 'System',    NULL,       '2026-09-18T18:00:00', '192.168.1.10');
GO

-- 4. PAYMENTS (10 filas)
INSERT INTO PAYMENTS (order_id, amount, payment_date, payment_method, reference_code, notes) VALUES
(1, 1250.00, '2026-09-02', 'WIRE_TRANSFER',    'TXN-0001', 'Pago total confirmado'),
(2, 3200.00, '2026-09-03', 'CREDIT_CARD',      'TXN-0002', 'Aprobado'),
(3, 1350.00, '2026-09-04', 'WIRE_TRANSFER',    'TXN-0003', 'Transferencia internacional'),
(4, 2940.00, '2026-09-05', 'PAYPAL',           'TXN-0004', 'Pago seguro'),
(5, 2520.00, '2026-09-06', 'WIRE_TRANSFER',    'TXN-0005', 'Adelanto 100%'),
(6, 8000.00, '2026-09-07', 'LETTER_OF_CREDIT', 'TXN-0006', 'Carta de credito aprobada'),
(7, 780.00,  '2026-09-08', 'CREDIT_CARD',      'TXN-0007', 'Pago en linea'),
(8, 1140.00, '2026-09-09', 'WIRE_TRANSFER',    'TXN-0008', 'Confirmado por finanzas'),
(9, 4650.00, '2026-09-10', 'WIRE_TRANSFER',    'TXN-0009', 'Saldo cancelado'),
(10,9750.00, '2026-09-11', 'LETTER_OF_CREDIT', 'TXN-0010', 'Confirmada por banco emisor');
GO

-- 5. INVOICES (10 filas)
INSERT INTO INVOICES (order_id, invoice_number, issue_date, due_date, currency, subtotal, taxes, total, status, document_type, exchange_rate, sunat_cdr_status) VALUES
(1,  'INV-001', '2026-09-02', '2026-10-02', 'USD', 1250.00, 0.00, 1250.00, 'PAID',    'FACTURA_EXP', 3.7500, 'ACEPTADO'),
(2,  'INV-002', '2026-09-03', '2026-10-03', 'USD', 3200.00, 0.00, 3200.00, 'PAID',    'FACTURA_EXP', 3.7520, 'ACEPTADO'),
(3,  'INV-003', '2026-09-04', '2026-10-04', 'EUR', 1350.00, 0.00, 1350.00, 'UNPAID',  'FACTURA_EXP', 4.1000, 'PENDIENTE'),
(4,  'INV-004', '2026-09-05', '2026-10-05', 'USD', 2940.00, 0.00, 2940.00, 'PARTIAL', 'FACTURA_EXP', 3.7480, 'ACEPTADO'),
(5,  'INV-005', '2026-09-06', '2026-10-06', 'USD', 2520.00, 0.00, 2520.00, 'PAID',    'FACTURA_EXP', 3.7500, 'ACEPTADO'),
(6,  'INV-006', '2026-09-07', '2026-10-07', 'USD', 8000.00, 0.00, 8000.00, 'PAID',    'FACTURA_EXP', 3.7510, 'ACEPTADO'),
(7,  'INV-007', '2026-09-08', '2026-10-08', 'EUR', 780.00,  0.00, 780.00,  'UNPAID',  'FACTURA_EXP', 4.1100, 'PENDIENTE'),
(8,  'INV-008', '2026-09-09', '2026-10-09', 'USD', 1140.00, 0.00, 1140.00, 'PAID',    'FACTURA_EXP', 3.7490, 'ACEPTADO'),
(9,  'INV-009', '2026-09-10', '2026-10-10', 'USD', 4650.00, 0.00, 4650.00, 'PARTIAL', 'FACTURA_EXP', 3.7530, 'ACEPTADO'),
(10, 'INV-010', '2026-09-11', '2026-10-11', 'USD', 9750.00, 0.00, 9750.00, 'PAID',    'FACTURA_EXP', 3.7500, 'ACEPTADO');
GO

-- 6. SHIPMENTS (10 filas)
INSERT INTO SHIPMENTS (order_id, bl_number, booking_number, freight_forwarder, vessel_name, container_number, departure_port, arrival_port, departure_date, estimated_arrival, status, temperature_setpoint) VALUES
(1,  'BL-1001', 'BKG-1001', 'KUEHNE+NAGEL', 'MSC ISABELLA',    'MSCU1234567', 'Callao', 'Rotterdam', '2026-09-15', '2026-10-05', 'DELIVERED',  4.0),
(2,  'BL-1002', 'BKG-1002', 'DHL GLOBAL', 'MAERSK MC-KINNEY','MSKU2345678', 'Paita',  'Hamburg',   '2026-09-16', '2026-10-08', 'DELIVERED',  3.5),
(3,  'BL-1003', 'BKG-1003', 'SCHENKER', 'CMA CGM ANTOINE', 'CMAU3456789', 'Callao', 'Valencia',  '2026-09-17', '2026-10-09', 'IN_TRANSIT', 4.0),
(4,  'BL-1004', 'BKG-1004', 'KUEHNE+NAGEL', 'HAPAG LLOYD RIO', 'HLCU4567890', 'Callao', 'Long Beach','2026-09-20', '2026-10-02', 'IN_TRANSIT', 3.8),
(5,  'BL-1005', 'BKG-1005', 'EXPEDITORS', 'ONE OLYMPUS',     'ONEU5678901', 'Paita',  'Miami',     '2026-09-21', '2026-10-03', 'IN_TRANSIT', 4.2),
(6,  'BL-1006', 'BKG-1006', 'DSV PANALPINA', 'EVER GIVEN',      'EGLV6789012', 'Callao', 'Yokohama',  '2026-09-22', '2026-10-15', 'IN_TRANSIT', 4.0),
(7,  'BL-1007', 'BKG-1007', 'KUEHNE+NAGEL', 'COSCO SHIPPING',  'COSU7890123', 'Callao', 'Antwerp',   '2026-09-23', '2026-10-16', 'IN_TRANSIT', 3.9),
(8,  'BL-1008', 'BKG-1008', 'DHL GLOBAL', 'YANG MING WISH',  'YMLU8901234', 'Paita',  'Busan',     '2026-09-25', '2026-10-18', 'DELIVERED',  4.1),
(9,  'BL-1009', 'BKG-1009', 'EXPEDITORS', 'PACIFIC VOYAGER', 'PCIU9012345', 'Callao', 'Callao',    '2026-09-26', '2026-09-30', 'PENDING',    4.0),
(10, 'BL-1010', 'BKG-1010', 'SCHENKER', 'ORIENTAL STAR',   'OOLU0123456', 'Callao', 'Shanghai',  '2026-09-27', '2026-10-22', 'PENDING',    3.7);
GO

-- 7. SHIPMENT_ITEMS (10 filas)
INSERT INTO SHIPMENT_ITEMS (shipment_id, product_id, quantity_pallets, quantity_boxes, net_weight_kg, gross_weight_kg) VALUES
(1,  'PROD-001', 10, 100, 500.00,  550.00),
(2,  'PROD-002', 20, 200, 1000.00, 1100.00),
(3,  'PROD-003', 15, 150, 750.00,  820.00),
(4,  'PROD-004', 24, 240, 1200.00, 1310.00),
(5,  'PROD-005', 16, 160, 800.00,  880.00),
(6,  'PROD-006', 40, 400, 2000.00, 2180.00),
(7,  'PROD-007', 6,  60,  300.00,  330.00),
(8,  'PROD-008', 12, 120, 600.00,  660.00),
(9,  'PROD-009', 30, 300, 1500.00, 1640.00),
(10, 'PROD-010', 50, 500, 2500.00, 2720.00);
GO

-- 8. CERTIFICATES (10 filas)
INSERT INTO CERTIFICATES (shipment_id, batch_id, type, issued_by, issue_date, expiry_date, certificate_number, file_url) VALUES
(1,  'BATCH-001', 'PHYTOSANITARY',         'SENASA', '2026-09-12', '2026-12-12', 'SEN-2026-001', 'https://docs.visons.com/cert/sen-001.pdf'),
(2,  'BATCH-002', 'CERTIFICATE_OF_ORIGIN', 'CAMARA COMERCIO', '2026-09-13', '2027-09-13', 'COO-2026-002', 'https://docs.visons.com/cert/coo-002.pdf'),
(3,  'BATCH-003', 'QUALITY_INSPECTION',    'SGS PERU', '2026-09-14', '2027-03-14', 'SGS-2026-003', 'https://docs.visons.com/cert/sgs-003.pdf'),
(4,  'BATCH-004', 'PHYTOSANITARY',         'SENASA', '2026-09-15', '2026-12-15', 'SEN-2026-004', 'https://docs.visons.com/cert/sen-004.pdf'),
(5,  'BATCH-005', 'CERTIFICATE_OF_ORIGIN', 'CAMARA COMERCIO', '2026-09-16', '2027-09-16', 'COO-2026-005', 'https://docs.visons.com/cert/coo-005.pdf'),
(6,  'BATCH-006', 'PHYTOSANITARY',         'SENASA', '2026-09-17', '2026-12-17', 'SEN-2026-006', 'https://docs.visons.com/cert/sen-006.pdf'),
(7,  'BATCH-007', 'ORGANIC_CERTIFICATION', 'CONTROL UNION', '2026-09-18', '2027-09-18', 'CU-2026-007',  'https://docs.visons.com/cert/cu-007.pdf'),
(8,  'BATCH-008', 'QUALITY_INSPECTION',    'BUREAU VERITAS', '2026-09-19', '2027-03-19', 'BV-2026-008', 'https://docs.visons.com/cert/bv-008.pdf'),
(9,  'BATCH-009', 'PHYTOSANITARY',         'SENASA', '2026-09-20', '2026-12-20', 'SEN-2026-009', 'https://docs.visons.com/cert/sen-009.pdf'),
(10, 'BATCH-010', 'CERTIFICATE_OF_ORIGIN', 'CAMARA COMERCIO', '2026-09-21', '2027-09-21', 'COO-2026-010', 'https://docs.visons.com/cert/coo-010.pdf');
GO

-- 9. CUSTOMS_DECLARATIONS (10 filas)
INSERT INTO CUSTOMS_DECLARATIONS (shipment_id, dam_number, fob_value, customs_agency, filing_date, status) VALUES
(1,  'DAM-118-001', 1250.00, 'AGENCIA RANGEL', '2026-09-14', 'CLEARED'),
(2,  'DAM-118-002', 3200.00, 'AGENCIA NEPTUNIA', '2026-09-15', 'CLEARED'),
(3,  'DAM-118-003', 1350.00, 'AGENCIA RANGEL', '2026-09-16', 'UNDER_INSPECTION'),
(4,  'DAM-118-004', 2940.00, 'AGENCIA TRANSOCEANICA', '2026-09-18', 'CLEARED'),
(5,  'DAM-118-005', 2520.00, 'AGENCIA NEPTUNIA', '2026-09-19', 'CLEARED'),
(6,  'DAM-118-006', 8000.00, 'AGENCIA RANGEL', '2026-09-20', 'UNDER_INSPECTION'),
(7,  'DAM-118-007', 780.00,  'AGENCIA TRANSOCEANICA', '2026-09-21', 'CLEARED'),
(8,  'DAM-118-008', 1140.00, 'AGENCIA NEPTUNIA', '2026-09-22', 'CLEARED'),
(9,  'DAM-118-009', 4650.00, 'AGENCIA RANGEL', '2026-09-24', 'PENDING'),
(10, 'DAM-118-010', 9750.00, 'AGENCIA TRANSOCEANICA', '2026-09-25', 'PENDING');
GO

-- 10. ASSIGNMENTS (10 filas)
INSERT INTO ASSIGNMENTS (order_id, assignment_type, assigned_to, assigned_by, priority, status, notes, assignment_date, due_date, completion_date) VALUES
(1,  'PACKING',     'U-002', 'U-001', 'HIGH',   'COMPLETED',   'Completado a tiempo', '2026-09-01', '2026-09-03', '2026-09-02'),
(2,  'INSPECTION',  'U-003', 'U-001', 'MEDIUM', 'COMPLETED',   'Inspeccion aprobada', '2026-09-02', '2026-09-04', '2026-09-03'),
(3,  'SHIPPING',    'U-004', 'U-001', 'HIGH',   'IN_PROGRESS', 'Cargando contenedores', '2026-09-03', '2026-09-05', NULL),
(4,  'PACKING',     'U-005', 'U-001', 'LOW',    'PENDING',     'Esperando paletas', '2026-09-04', '2026-09-06', NULL),
(5,  'INSPECTION',  'U-006', 'U-001', 'HIGH',   'PENDING',     'Toma de muestras', '2026-09-05', '2026-09-07', NULL),
(6,  'CUSTOMS',     'U-007', 'U-001', 'HIGH',   'IN_PROGRESS', 'Documentos en aduana', '2026-09-06', '2026-09-08', NULL),
(7,  'PACKING',     'U-008', 'U-001', 'MEDIUM', 'COMPLETED',   'Empacado y pesado', '2026-09-07', '2026-09-09', '2026-09-08'),
(8,  'COLD_CHAIN',  'U-009', 'U-001', 'HIGH',   'IN_PROGRESS', 'Monitoreo de frio', '2026-09-08', '2026-09-10', NULL),
(9,  'TRACEABILITY','U-010', 'U-001', 'MEDIUM', 'PENDING',     'Registro de lote', '2026-09-09', '2026-09-11', NULL),
(10, 'AUDIT',       'U-002', 'U-001', 'LOW',    'COMPLETED',   'Auditoria interna ok', '2026-09-10', '2026-09-12', '2026-09-11');
GO

-- 11. BATCHES (10 filas)
INSERT INTO BATCHES (product_code, provider_id, field_name, harvest_date, packing_date, production_date, expiration_date) VALUES
('PROD-001', 'PROV-001', 'Fundo Los Olivos', '2026-08-25', '2026-08-27', '2026-08-28', '2027-02-28'),
('PROD-002', 'PROV-002', 'Fundo Santa Rosa', '2026-08-26', '2026-08-28', '2026-08-29', '2027-03-01'),
('PROD-003', 'PROV-003', 'Fundo El Parral',  '2026-08-27', '2026-08-29', '2026-08-30', '2027-03-02'),
('PROD-004', 'PROV-004', 'Fundo San Jose',   '2026-08-28', '2026-08-30', '2026-08-31', '2027-03-05'),
('PROD-005', 'PROV-005', 'Fundo Esperanza',  '2026-08-29', '2026-08-31', '2026-09-01', '2027-03-10'),
('PROD-006', 'PROV-006', 'Fundo La Palma',   '2026-08-30', '2026-09-01', '2026-09-02', '2027-03-15'),
('PROD-007', 'PROV-007', 'Fundo Bella Vista','2026-08-31', '2026-09-02', '2026-09-03', '2027-03-20'),
('PROD-008', 'PROV-008', 'Fundo El Milagro', '2026-09-01', '2026-09-03', '2026-09-04', '2027-03-25'),
('PROD-009', 'PROV-009', 'Fundo San Juan',   '2026-09-02', '2026-09-04', '2026-09-05', '2027-03-28'),
('PROD-010', 'PROV-010', 'Fundo La Herradura','2026-09-03', '2026-09-05', '2026-09-06', '2027-04-01');
GO

-- 6. Historial de versiones del esquema en control.schema_change
INSERT INTO control.schema_change (sequence, change_id, checksum, git_sha, release_version, applied_at) VALUES
(1, 'V001__baseline',                     'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'main-release-2026', 'v1.0.0', SYSDATETIME()),
(2, 'V002__add_status_description',       'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0', 'main-release-2026', 'v1.1.0', SYSDATETIME()),
(3, 'V003__add_assignments_and_batches',   'b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef01', 'main-release-2026', 'v1.2.0', SYSDATETIME()),
(4, 'V004__update_orders_invoices',        'c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef012', 'main-release-2026', 'v1.3.0', SYSDATETIME());
GO

PRINT '=====================================================================';
PRINT '[SUCCESS] SQL Server: 11 Tablas de negocio + control creadas y cargadas con 10 registros cada una.';
PRINT '=====================================================================';
GO

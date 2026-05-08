-- F2 — Bootstrap del schema cdt en cada cluster Postgres por país.
-- Componente: AlmacenCDTXPais (Datos) — apoya ASR-1 (latencia) y ASR-2 (escalabilidad).
-- Documentación: docs/experimento_asr.md §6.4.3
-- Ejecutado por CloudNativePG via postInitApplicationSQLRefs (ver Cluster CR).

CREATE SCHEMA IF NOT EXISTS cdt;
GRANT USAGE ON SCHEMA cdt TO app;
GRANT ALL ON SCHEMA cdt TO app;
ALTER DEFAULT PRIVILEGES FOR USER app IN SCHEMA cdt GRANT ALL ON TABLES TO app;
ALTER DEFAULT PRIVILEGES FOR USER app IN SCHEMA cdt GRANT USAGE, SELECT ON SEQUENCES TO app;

-- Tabla principal: ciclo de vida del CDT.
-- Estados según diagrama de clases: PENDIENTE → ACTIVO → CONGELADO (este último por DetectorFraude en F8).
CREATE TABLE IF NOT EXISTS cdt.cdt (
    id              UUID         PRIMARY KEY,
    pais            VARCHAR(2)   NOT NULL CHECK (pais IN ('pe', 'mx', 'co')),
    cliente_id      VARCHAR(64)  NOT NULL,
    monto           NUMERIC(15,2) NOT NULL CHECK (monto > 0),
    plazo_dias      INT          NOT NULL CHECK (plazo_dias > 0),
    tasa_anual      NUMERIC(5,4) NOT NULL CHECK (tasa_anual >= 0),
    estado          VARCHAR(20)  NOT NULL DEFAULT 'PENDIENTE'
                    CHECK (estado IN ('PENDIENTE', 'ACTIVO', 'CONGELADO')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Índices alineados a las consultas esperadas:
--   - lookup por cliente (consulta de saldos)
--   - reporte por estado y rango temporal
CREATE INDEX IF NOT EXISTS idx_cdt_cliente
    ON cdt.cdt (cliente_id);

CREATE INDEX IF NOT EXISTS idx_cdt_estado_created
    ON cdt.cdt (estado, created_at DESC);

GRANT SELECT, INSERT, UPDATE ON cdt.cdt TO app;

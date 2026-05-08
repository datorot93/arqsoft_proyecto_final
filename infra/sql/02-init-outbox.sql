-- F2 — Tabla outbox para el patrón Outbox Pattern (Hohpe / Vernon).
-- Detalle de implementación; NO es un componente nuevo del modelo (ver CLAUDE.md).
-- El outbox-dispatcher (F4) lee esta tabla y publica al MessageBroker.
-- Documentación: docs/experimento_asr.md §6.4.3, §3.1

CREATE TABLE IF NOT EXISTS cdt.outbox_cdt_eventos (
    id                BIGSERIAL    PRIMARY KEY,
    cdt_id            UUID         NOT NULL,
    aggregate_type    VARCHAR(50)  NOT NULL DEFAULT 'CDT',
    event_type        VARCHAR(50)  NOT NULL,            -- ej: CDTAbiertoEvent
    payload           JSONB        NOT NULL,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    published_at      TIMESTAMPTZ,
    publish_attempts  INT          NOT NULL DEFAULT 0,

    CONSTRAINT fk_outbox_cdt FOREIGN KEY (cdt_id) REFERENCES cdt.cdt(id) ON DELETE CASCADE
);

-- Índice clave para el dispatcher (poll por filas no publicadas):
--   WHERE published_at IS NULL ORDER BY created_at LIMIT N FOR UPDATE SKIP LOCKED
CREATE INDEX IF NOT EXISTS idx_outbox_pending
    ON cdt.outbox_cdt_eventos (created_at)
    WHERE published_at IS NULL;

-- Lookup por cdt_id (búsqueda de eventos de un CDT específico)
CREATE INDEX IF NOT EXISTS idx_outbox_cdt_id
    ON cdt.outbox_cdt_eventos (cdt_id);

GRANT SELECT, INSERT, UPDATE ON cdt.outbox_cdt_eventos TO app;
GRANT USAGE, SELECT ON SEQUENCE cdt.outbox_cdt_eventos_id_seq TO app;

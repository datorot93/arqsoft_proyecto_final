package co.bancoz.lineaverde.commons.events;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/**
 * Evento de dominio emitido cuando se abre un CDT.
 * Se serializa a JSON y se almacena en cdt.outbox_cdt_eventos.payload (JSONB).
 * El outbox-dispatcher lo publica al topic cdt.eventos de Redpanda.
 *
 * Decisión: record immutable — adecuado para eventos de dominio.
 */
public record CdtAbiertoEvent(
        UUID cdtId,
        String pais,
        String clienteId,
        BigDecimal monto,
        int plazoDias,
        BigDecimal tasaAnual,
        Instant timestamp
) {
    /** Nombre canónico del event_type en la tabla outbox. */
    public static final String EVENT_TYPE = "CDTAbiertoEvent";
    /** aggregate_type en la tabla outbox. */
    public static final String AGGREGATE_TYPE = "CDT";
}

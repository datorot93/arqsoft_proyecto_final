package co.bancoz.lineaverde.cdtpais.persistence;

import co.bancoz.lineaverde.commons.events.CdtAbiertoEvent;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.UUID;

/**
 * Repositorio del patrón Outbox Pattern.
 * Escribe en cdt.outbox_cdt_eventos dentro de la misma transacción que CdtRepository.insert().
 * Schema definido en infra/sql/02-init-outbox.sql — NO modificar.
 *
 * NOTA ARQUITECTÓNICA: outbox-dispatcher NO es un componente del modelo.
 * Es un detalle de implementación del patrón Outbox (ver CLAUDE.md y commit F4).
 */
@Repository
public class OutboxRepository {

    private static final Logger log = LoggerFactory.getLogger(OutboxRepository.class);

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;

    public OutboxRepository(JdbcTemplate jdbc, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
    }

    /**
     * Inserta un evento en la tabla outbox.
     * published_at queda NULL: el outbox-dispatcher lo llenará tras el ack del broker.
     *
     * @param cdtId     UUID del CDT recién creado.
     * @param event     Evento de dominio a serializar como JSONB.
     */
    public void insertEvent(UUID cdtId, CdtAbiertoEvent event) {
        String payloadJson;
        try {
            payloadJson = objectMapper.writeValueAsString(event);
        } catch (JsonProcessingException e) {
            // No debería ocurrir con un record bien formado
            throw new IllegalStateException("No se pudo serializar CdtAbiertoEvent", e);
        }

        jdbc.update("""
                INSERT INTO cdt.outbox_cdt_eventos
                  (cdt_id, aggregate_type, event_type, payload, created_at, publish_attempts)
                VALUES
                  (?::uuid, ?, ?, ?::jsonb, NOW(), 0)
                """,
                cdtId.toString(),
                CdtAbiertoEvent.AGGREGATE_TYPE,
                CdtAbiertoEvent.EVENT_TYPE,
                payloadJson
        );

        log.debug("Evento outbox insertado: cdtId={}, tipo={}", cdtId, CdtAbiertoEvent.EVENT_TYPE);
    }
}

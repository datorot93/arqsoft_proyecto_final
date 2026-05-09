package co.bancoz.lineaverde.outbox.poller;

import co.bancoz.lineaverde.outbox.publisher.EventPublisher;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Poller del patrón Outbox. Lee filas no publicadas de cdt.outbox_cdt_eventos
 * y las publica al topic cdt.eventos de Redpanda.
 *
 * Característica clave (spec F4, regla 5):
 *   FOR UPDATE SKIP LOCKED — permite múltiples instancias del dispatcher sin colisiones.
 *   LIMIT 100 — procesa en lotes para evitar acumulación bajo carga alta.
 *
 * Flujo por fila:
 *   1. SELECT ... FOR UPDATE SKIP LOCKED LIMIT 100
 *   2. Para cada fila: EventPublisher.publish() con callback de ack.
 *   3. En el ack callback: UPDATE published_at=NOW(), incrementa publish_attempts.
 *   4. En caso de error: incrementa publish_attempts (retry en el siguiente ciclo).
 *
 * Nota: el publish es async (KafkaTemplate retorna CompletableFuture), pero el
 * SELECT ocurre dentro de @Transactional. El UPDATE se hace en el ack callback.
 *
 * Métricas (P5 experimento_asr.md §5.2):
 *   - outbox_dispatch_lag_seconds: ahora - created_at de la fila más antigua sin publicar.
 *   - outbox_dispatch_total{result=success|failure}: contadores de dispatch.
 *   - outbox_dispatch_duration_seconds: duración del ciclo de polling.
 */
@Component
public class OutboxPoller {

    private static final Logger log = LoggerFactory.getLogger(OutboxPoller.class);

    private static final String SELECT_PENDING = """
            SELECT id, cdt_id::text, event_type, payload::text, created_at
            FROM cdt.outbox_cdt_eventos
            WHERE published_at IS NULL
            ORDER BY created_at
            LIMIT 100
            FOR UPDATE SKIP LOCKED
            """;

    private static final String UPDATE_PUBLISHED = """
            UPDATE cdt.outbox_cdt_eventos
            SET published_at = ?, publish_attempts = publish_attempts + 1
            WHERE id = ?
            """;

    private static final String UPDATE_FAILED = """
            UPDATE cdt.outbox_cdt_eventos
            SET publish_attempts = publish_attempts + 1
            WHERE id = ?
            """;

    private static final String SELECT_LAG = """
            SELECT EXTRACT(EPOCH FROM (NOW() - MIN(created_at)))
            FROM cdt.outbox_cdt_eventos
            WHERE published_at IS NULL
            """;

    private final JdbcTemplate jdbc;
    private final EventPublisher publisher;

    // Métricas Micrometer
    private final Counter successCounter;
    private final Counter failureCounter;
    private final Timer dispatchTimer;
    private final AtomicLong lagSeconds = new AtomicLong(0);

    public OutboxPoller(JdbcTemplate jdbc, EventPublisher publisher, MeterRegistry meterRegistry) {
        this.jdbc = jdbc;
        this.publisher = publisher;

        this.successCounter = Counter.builder("outbox_dispatch_total")
                .tag("result", "success")
                .description("Eventos publicados exitosamente al broker")
                .register(meterRegistry);

        this.failureCounter = Counter.builder("outbox_dispatch_total")
                .tag("result", "failure")
                .description("Fallos de publicación al broker")
                .register(meterRegistry);

        this.dispatchTimer = Timer.builder("outbox_dispatch_duration_seconds")
                .description("Duración del ciclo de polling del outbox — P5 experimento ASR-1")
                .register(meterRegistry);

        // Gauge de lag: cuánto tiempo llevan las filas más antiguas sin publicarse
        Gauge.builder("outbox_dispatch_lag_seconds", lagSeconds, AtomicLong::get)
                .description("Lag del outbox: segundos desde created_at de la fila más antigua sin publicar")
                .register(meterRegistry);
    }

    /**
     * Ciclo de polling cada 200 ms (configurable por env).
     * fixedDelay garantiza que el siguiente ciclo empiece 200ms DESPUÉS de que
     * termine el anterior (no overlap entre ciclos).
     */
    @Scheduled(fixedDelayString = "${outbox.poll-interval-ms:200}")
    @Transactional
    public void poll() {
        dispatchTimer.record(() -> {
            try {
                List<Map<String, Object>> pendingRows = jdbc.queryForList(SELECT_PENDING);

                if (pendingRows.isEmpty()) {
                    updateLagMetric();
                    return;
                }

                log.debug("Outbox: {} filas pendientes encontradas", pendingRows.size());

                for (Map<String, Object> row : pendingRows) {
                    long id = ((Number) row.get("id")).longValue();
                    String cdtId = (String) row.get("cdt_id");
                    String payload = (String) row.get("payload");

                    publisher.publish(
                            cdtId,
                            payload,
                            // Callback de éxito (ack del broker)
                            result -> markPublished(id),
                            // Callback de error
                            ex -> {
                                log.warn("Fallo publicando outbox id={}: {}", id, ex.getMessage());
                                markFailed(id);
                                failureCounter.increment();
                            }
                    );
                }

                updateLagMetric();

            } catch (Exception e) {
                log.error("Error en ciclo de polling del outbox: {}", e.getMessage(), e);
            }
        });
    }

    private void markPublished(long outboxId) {
        try {
            int updated = jdbc.update(UPDATE_PUBLISHED, Timestamp.from(Instant.now()), outboxId);
            if (updated > 0) {
                successCounter.increment();
                log.debug("Outbox id={} marcado como publicado", outboxId);
            }
        } catch (Exception e) {
            log.error("Error marcando outbox id={} como publicado: {}", outboxId, e.getMessage());
        }
    }

    private void markFailed(long outboxId) {
        try {
            jdbc.update(UPDATE_FAILED, outboxId);
        } catch (Exception e) {
            log.error("Error actualizando publish_attempts para outbox id={}: {}", outboxId, e.getMessage());
        }
    }

    private void updateLagMetric() {
        try {
            Double lag = jdbc.queryForObject(SELECT_LAG, Double.class);
            lagSeconds.set(lag != null ? lag.longValue() : 0);
        } catch (Exception e) {
            // No crítico — la métrica de lag es informativa
            lagSeconds.set(0);
        }
    }
}

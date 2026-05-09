package co.bancoz.lineaverde.outbox;

import co.bancoz.lineaverde.outbox.poller.OutboxPoller;
import co.bancoz.lineaverde.outbox.publisher.EventPublisher;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios del OutboxPoller.
 *
 * Verifica:
 *   - Que las filas pendientes se procesan correctamente (llamada a publisher).
 *   - Que cuando no hay filas, no se llama al publisher.
 *   - Que el UPDATE published_at ocurre cuando el ack del broker llega.
 *   - Que el UPDATE de publish_attempts ocurre en caso de error.
 */
@ExtendWith(MockitoExtension.class)
class OutboxPollerTest {

    @Mock
    private JdbcTemplate jdbcTemplate;

    @Mock
    private EventPublisher publisher;

    private OutboxPoller poller;

    @BeforeEach
    void setUp() {
        var meterRegistry = new SimpleMeterRegistry();
        poller = new OutboxPoller(jdbcTemplate, publisher, meterRegistry);
    }

    @Test
    void poll_sinFilasPendientes_noLlamaPublisher() {
        // Arrange: tabla vacía
        when(jdbcTemplate.queryForList(anyString())).thenReturn(Collections.emptyList());
        when(jdbcTemplate.queryForObject(anyString(), eq(Double.class))).thenReturn(0.0);

        // Act
        poller.poll();

        // Assert
        verify(publisher, never()).publish(any(), any(), any(), any());
    }

    @Test
    void poll_conFilasPendientes_llamaPublisherPorCadaFila() {
        // Arrange: 2 filas pendientes
        List<Map<String, Object>> rows = List.of(
                Map.of("id", 1L, "cdt_id", "uuid-1", "event_type", "CDTAbiertoEvent",
                       "payload", "{\"cdtId\":\"uuid-1\"}", "created_at", Timestamp.from(Instant.now())),
                Map.of("id", 2L, "cdt_id", "uuid-2", "event_type", "CDTAbiertoEvent",
                       "payload", "{\"cdtId\":\"uuid-2\"}", "created_at", Timestamp.from(Instant.now()))
        );
        when(jdbcTemplate.queryForList(anyString())).thenReturn(rows);
        when(jdbcTemplate.queryForObject(anyString(), eq(Double.class))).thenReturn(0.1);

        // Act
        poller.poll();

        // Assert: publisher llamado 2 veces con las claves correctas
        verify(publisher, times(1)).publish(eq("uuid-1"), anyString(), any(), any());
        verify(publisher, times(1)).publish(eq("uuid-2"), anyString(), any(), any());
    }

    @Test
    @SuppressWarnings("unchecked")
    void poll_enAck_marcaPublishedAt() {
        // Arrange: una fila pendiente
        List<Map<String, Object>> rows = List.of(
                Map.of("id", 42L, "cdt_id", "uuid-42", "event_type", "CDTAbiertoEvent",
                       "payload", "{}", "created_at", Timestamp.from(Instant.now()))
        );
        when(jdbcTemplate.queryForList(anyString())).thenReturn(rows);
        when(jdbcTemplate.queryForObject(anyString(), eq(Double.class))).thenReturn(0.0);
        when(jdbcTemplate.update(anyString(), any(Timestamp.class), eq(42L))).thenReturn(1);

        // Capturar el callback de onAck para invocarlo manualmente
        ArgumentCaptor<Consumer> ackCaptor = ArgumentCaptor.forClass(Consumer.class);
        doAnswer(inv -> {
            // Invocar inmediatamente el callback onAck simulando ack del broker
            ((Consumer) inv.getArgument(2)).accept(null);
            return null;
        }).when(publisher).publish(anyString(), anyString(), any(), any());

        // Act
        poller.poll();

        // Assert: UPDATE published_at llamado con el id correcto
        verify(jdbcTemplate).update(anyString(), any(Timestamp.class), eq(42L));
    }

    @Test
    @SuppressWarnings("unchecked")
    void poll_enError_incrementaPublishAttempts() {
        // Arrange: una fila pendiente
        List<Map<String, Object>> rows = List.of(
                Map.of("id", 99L, "cdt_id", "uuid-99", "event_type", "CDTAbiertoEvent",
                       "payload", "{}", "created_at", Timestamp.from(Instant.now()))
        );
        when(jdbcTemplate.queryForList(anyString())).thenReturn(rows);
        when(jdbcTemplate.queryForObject(anyString(), eq(Double.class))).thenReturn(0.0);

        // Simular error en publisher: invocar el callback onError
        doAnswer(inv -> {
            ((Consumer) inv.getArgument(3)).accept(new RuntimeException("Broker no disponible"));
            return null;
        }).when(publisher).publish(anyString(), anyString(), any(), any());

        // Act
        poller.poll();

        // Assert: UPDATE publish_attempts (la query de fallo, NO la de published_at)
        // La query de fallo solo actualiza publish_attempts, sin published_at.
        // Verificamos que se llamó al menos una vez con el id correcto.
        verify(jdbcTemplate, atLeastOnce()).update(contains("publish_attempts"), eq(99L));
    }
}

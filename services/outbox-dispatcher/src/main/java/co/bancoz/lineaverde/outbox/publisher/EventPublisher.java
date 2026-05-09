package co.bancoz.lineaverde.outbox.publisher;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.SendResult;
import org.springframework.stereotype.Component;

import java.util.concurrent.CompletableFuture;
import java.util.function.Consumer;

/**
 * Publicador de eventos al topic cdt.eventos en Redpanda.
 * Usa KafkaTemplate de Spring Kafka 3.2.x.
 *
 * Kafka client apunta a Redpanda puerto 9093 (interno) — gotcha F2:
 * el puerto 9092 es para clientes externos; el 9093 es el listener interno del cluster.
 */
@Component
public class EventPublisher {

    private static final Logger log = LoggerFactory.getLogger(EventPublisher.class);
    private static final String TOPIC = "cdt.eventos";

    private final KafkaTemplate<String, String> kafkaTemplate;

    public EventPublisher(KafkaTemplate<String, String> kafkaTemplate) {
        this.kafkaTemplate = kafkaTemplate;
    }

    /**
     * Publica un evento al topic cdt.eventos con la clave cdtId.
     * La clave garantiza que eventos del mismo CDT van a la misma partición (orden).
     *
     * @param cdtId    Clave del mensaje (UUID como String).
     * @param payload  Payload JSON del evento.
     * @param onAck    Callback invocado cuando el broker confirma la recepción.
     * @param onError  Callback invocado si la publicación falla tras reintentos.
     */
    public void publish(String cdtId, String payload,
                        Consumer<SendResult<String, String>> onAck,
                        Consumer<Throwable> onError) {
        CompletableFuture<SendResult<String, String>> future =
                kafkaTemplate.send(TOPIC, cdtId, payload);

        future.whenComplete((result, ex) -> {
            if (ex != null) {
                log.error("Error publicando evento cdtId={} al topic {}: {}",
                          cdtId, TOPIC, ex.getMessage());
                onError.accept(ex);
            } else {
                log.debug("Evento publicado: cdtId={}, partition={}, offset={}",
                          cdtId,
                          result.getRecordMetadata().partition(),
                          result.getRecordMetadata().offset());
                onAck.accept(result);
            }
        });
    }
}

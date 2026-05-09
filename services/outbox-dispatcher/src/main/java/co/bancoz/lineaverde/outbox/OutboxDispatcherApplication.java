package co.bancoz.lineaverde.outbox;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Outbox Dispatcher — implementa el patrón Outbox Pattern (Hohpe / Vernon).
 *
 * NOTA ARQUITECTÓNICA: este servicio NO es un componente del modelo
 * (no aparece en diagramas_final/componentes.jpeg). Es un detalle de
 * implementación del patrón Outbox que materializa la publicación asíncrona
 * de eventos de dominio al MessageBroker. El componente en el modelo es
 * CDTXPais (que escribe el outbox) + MessageBroker (que recibe los eventos).
 *
 * Una réplica por país (env LV_PAIS). Polling cada 200ms.
 */
@SpringBootApplication
@EnableScheduling
public class OutboxDispatcherApplication {

    public static void main(String[] args) {
        SpringApplication.run(OutboxDispatcherApplication.class, args);
    }
}

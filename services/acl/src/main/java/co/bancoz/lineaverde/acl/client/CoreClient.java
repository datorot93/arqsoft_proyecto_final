package co.bancoz.lineaverde.acl.client;

import co.bancoz.lineaverde.acl.api.ReservarRequest;
import co.bancoz.lineaverde.acl.api.ReservarResponse;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.Map;

/**
 * Cliente HTTP directo al core-stub.
 * Usa RestClient (Spring Boot 3.2+) con pool de conexiones acotado
 * via PoolingHttpClientConnectionManager (Apache HttpComponents 5).
 *
 * Instrumentación P6 (docs/experimento_asr.md §5.2):
 *   Timer "core_call_duration_seconds" mide SOLO el tiempo del HTTP call efectivo,
 *   SIN incluir el overhead del CircuitBreaker o el Retry.
 *
 * URL hardcoded por diseño: core-stub.core-stub.svc.cluster.local es el único
 * destino del ACL. Parametrizable por env CORE_STUB_URL para pruebas.
 */
@Component
public class CoreClient {

    private static final Logger log = LoggerFactory.getLogger(CoreClient.class);

    @Value("${acl.core-stub.url:http://core-stub.core-stub.svc.cluster.local:8080}")
    private String coreStubUrl;

    private final RestClient restClient;
    private final Timer coreCallTimer;

    public CoreClient(RestClient restClient, MeterRegistry meterRegistry) {
        this.restClient = restClient;
        // P6: mide duración de la llamada HTTP efectiva al core
        this.coreCallTimer = Timer.builder("core_call_duration_seconds")
                .description("Duración de la llamada HTTP al core bancario — P6 experimento ASR-1")
                .register(meterRegistry);
    }

    /**
     * Llama a POST /core/reservar en core-stub.
     * Mide la duración con el timer P6.
     *
     * @param req Solicitud de reserva (dominio Línea Verde).
     * @return Respuesta del core (dominio traducido por TraductorDominio).
     * @throws org.springframework.web.client.HttpClientErrorException si el core responde 4xx
     * @throws org.springframework.web.client.HttpServerErrorException si el core responde 5xx (e.g. Bernoulli error)
     */
    public ReservarResponse llamarCore(ReservarRequest req) {
        return coreCallTimer.record(() -> {
            log.debug("Llamando a core-stub: cdtId={}", req.cdtId());

            // Traducción del dominio (TraductorDominio): ReservarRequest → payload del core
            Map<String, Object> corePayload = Map.of(
                    "referencia", req.cdtId().toString(),
                    "cliente",    req.clienteId(),
                    "monto",      req.monto(),
                    "plazo",      req.plazoDias(),
                    "tasa",       req.tasaAnual(),
                    "pais",       req.pais()
            );

            // Llamada HTTP con RestClient — el pool está configurado en HttpClientConfig.
            // Si el caller del ACL envió X-Stub-Error-Rate (tests del gate), propagarlo al core-stub.
            String errorRate = CoreCallContext.getErrorRate();
            var requestSpec = restClient.post()
                    .uri(coreStubUrl + "/core/reservar")
                    .contentType(MediaType.APPLICATION_JSON);
            if (errorRate != null) {
                requestSpec = requestSpec.header("X-Stub-Error-Rate", errorRate);
            }
            var coreResp = requestSpec
                    .body(corePayload)
                    .retrieve()
                    .toEntity(Map.class);

            // Traducción de vuelta al dominio Línea Verde
            @SuppressWarnings("unchecked")
            Map<String, Object> body = coreResp.getBody();
            String status = body != null ? (String) body.getOrDefault("status", "DESCONOCIDO") : "ERROR";

            log.debug("Core respondió: cdtId={}, status={}", req.cdtId(), status);
            return new ReservarResponse(req.cdtId(), status, "Procesado por CoreBancoZ");
        });
    }
}

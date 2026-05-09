package co.bancoz.lineaverde.acl.client;

import co.bancoz.lineaverde.acl.api.ReservarRequest;
import co.bancoz.lineaverde.acl.api.ReservarResponse;
import io.github.resilience4j.bulkhead.annotation.Bulkhead;
import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import io.github.resilience4j.retry.annotation.Retry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * Cliente resiliente al core bancario.
 * Combina CircuitBreaker + Bulkhead + Retry con las configuraciones del spec.
 *
 * CircuitBreaker "core":
 *   - slidingWindowType: COUNT_BASED, size: 20
 *   - failureRateThreshold: 50%
 *   - waitDurationInOpenState: 30s
 *   - permittedNumberOfCallsInHalfOpenState: 3
 *
 * Bulkhead "core": maxConcurrentCalls: 20
 *
 * Retry "core": maxAttempts: 3, exponentialBackoff × 2.0 con jitter
 *
 * El orden de aplicación (más externo al más interno): CB → Bulkhead → Retry → llamada.
 * Nota: Resilience4j aplica en orden de las anotaciones de abajo a arriba en bytecode,
 * pero la configuración en application.yml es la que controla el comportamiento real.
 */
@Component
public class ResilientCoreClient {

    private static final Logger log = LoggerFactory.getLogger(ResilientCoreClient.class);

    private final CoreClient coreClient;

    public ResilientCoreClient(CoreClient coreClient) {
        this.coreClient = coreClient;
    }

    /**
     * Llama al core con protección resiliente.
     *
     * Si el CB está OPEN, lanza CallNotPermittedException → fallbackMethod.
     * Si el Bulkhead está saturado, lanza BulkheadFullException → fallbackMethod.
     * Si todos los reintentos fallan, lanza la última excepción → fallbackMethod.
     */
    // NOTA: el fallback se declara SOLO en el outer-most decorator (@CircuitBreaker).
    // Si lo agregamos también a @Retry o @Bulkhead, esos lo invocan ANTES de que el CB
    // vea la excepción y entonces el CB cuenta el call como successful — falla el gate T-7.
    @CircuitBreaker(name = "core", fallbackMethod = "reservarFallback")
    @Bulkhead(name = "core")
    @Retry(name = "core")
    public ReservarResponse reservar(ReservarRequest req) {
        return coreClient.llamarCore(req);
    }

    /**
     * Fallback cuando el CircuitBreaker está abierto, el Bulkhead saturado,
     * o todos los reintentos agotados.
     *
     * Retorna una respuesta degradada. El CDT ya fue insertado como PENDIENTE;
     * la confirmación de ACTIVO llegará cuando el core se recupere.
     */
    @SuppressWarnings("unused") // Invocado por Resilience4j via reflexión
    public ReservarResponse reservarFallback(ReservarRequest req, Throwable t) {
        log.warn("Fallback activado para cdtId={}: {} — {}",
                 req.cdtId(), t.getClass().getSimpleName(), t.getMessage());
        return new ReservarResponse(req.cdtId(), "PENDIENTE", "Core no disponible — CDT en estado PENDIENTE");
    }
}

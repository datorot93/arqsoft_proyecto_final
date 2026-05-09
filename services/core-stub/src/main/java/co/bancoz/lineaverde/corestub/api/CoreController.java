package co.bancoz.lineaverde.corestub.api;

import co.bancoz.lineaverde.corestub.distributions.BernoulliSampler;
import co.bancoz.lineaverde.corestub.distributions.ParetoSampler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

/**
 * Stub del endpoint del CoreBancoZ.
 *
 * Simula el comportamiento real del core:
 *   - Latencia: muestreada de Pareto(xm=80ms, α=2.5) — heavy tail
 *   - Error: Bernoulli(p) — configurable por header o env
 *
 * El header X-Stub-Error-Rate permite a k6 (F5) controlar la tasa de error
 * durante la simulación de degradación del core (test F4.T-7).
 *
 * IMPORTANTE: este endpoint es SOLO accesible desde el namespace acl
 * (NetworkPolicy core-stub-ingress-from-acl-only en F1).
 */
@RestController
@RequestMapping("/core")
public class CoreController {

    private static final Logger log = LoggerFactory.getLogger(CoreController.class);

    @Value("${stub.error-rate-default:0.0}")
    private double defaultErrorRate;

    private final ParetoSampler paretoSampler;
    private final BernoulliSampler bernoulliSampler;

    public CoreController(ParetoSampler paretoSampler, BernoulliSampler bernoulliSampler) {
        this.paretoSampler = paretoSampler;
        this.bernoulliSampler = bernoulliSampler;
    }

    /**
     * POST /core/reservar — simula la reserva de CDT en el core bancario.
     *
     * @param errorRate Header X-Stub-Error-Rate para override de p (opcional).
     * @param body      Payload del request (ignorado en el stub; solo validamos que no sea nulo).
     * @return 200 con latencia Pareto, o 503 con Bernoulli.
     */
    @PostMapping("/reservar")
    public ResponseEntity<Map<String, Object>> reservar(
            @RequestHeader(value = "X-Stub-Error-Rate", required = false) Double errorRate,
            @RequestBody(required = false) Map<String, Object> body) {

        double p = (errorRate != null) ? errorRate : defaultErrorRate;

        // Ensayo Bernoulli — ¿responder con error?
        if (bernoulliSampler.shouldFail(p)) {
            log.debug("CoreStub: error Bernoulli(p={}) — retornando 503", p);
            return ResponseEntity.status(503)
                    .body(Map.of("error", "CoreBancoZ no disponible", "errorRate", p));
        }

        // Latencia Pareto — simular tiempo de procesamiento del core
        long latencyMs = paretoSampler.sample();
        log.debug("CoreStub: procesando con latencia={}ms, errorRate={}", latencyMs, p);

        try {
            Thread.sleep(latencyMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            log.warn("CoreStub: sleep interrumpido para latencyMs={}", latencyMs);
        }

        return ResponseEntity.ok(Map.of(
                "status", "RESERVADO",
                "latencyMs", latencyMs,
                "referencia", body != null ? body.getOrDefault("referencia", "N/A") : "N/A"
        ));
    }

    /**
     * GET /core/health — health check simple del stub.
     */
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP", "service", "core-stub"));
    }
}

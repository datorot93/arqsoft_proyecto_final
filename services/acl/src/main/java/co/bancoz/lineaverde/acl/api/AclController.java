package co.bancoz.lineaverde.acl.api;

import co.bancoz.lineaverde.acl.client.CoreCallContext;
import co.bancoz.lineaverde.acl.client.ResilientCoreClient;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * Controlador del ACL (Anti-Corruption Layer).
 * Expone POST /acl/reservar — proxy resiliente hacia el core bancario.
 *
 * El caller (cdt-pais u outbox-dispatcher) envía el CDT y este servicio
 * traduce el dominio Línea Verde al dominio CoreBancoZ.
 *
 * Regla arquitectónica: NUNCA exponemos la URL del core al caller.
 * El ACL es el único que conoce core-stub.core-stub.svc.cluster.local.
 */
@RestController
@RequestMapping("/acl")
public class AclController {

    private static final Logger log = LoggerFactory.getLogger(AclController.class);

    private final ResilientCoreClient coreClient;

    public AclController(ResilientCoreClient coreClient) {
        this.coreClient = coreClient;
    }

    /**
     * POST /acl/reservar — traduce y envía la solicitud al core bancario.
     * Con Resilience4j: CircuitBreaker + Bulkhead + Retry (configurados en application.yml).
     */
    @PostMapping("/reservar")
    public ResponseEntity<ReservarResponse> reservar(
            @Valid @RequestBody ReservarRequest req,
            @RequestHeader(value = "X-Stub-Error-Rate", required = false) String errorRate) {
        log.debug("ACL: reserva recibida para cdtId={}, pais={}", req.cdtId(), req.pais());
        if (errorRate != null) {
            CoreCallContext.setErrorRate(errorRate);
        }
        try {
            ReservarResponse response = coreClient.reservar(req);
            return ResponseEntity.ok(response);
        } finally {
            CoreCallContext.clear();
        }
    }
}

package co.bancoz.lineaverde.cdtpais.api;

import co.bancoz.lineaverde.cdtpais.domain.CdtService;
import co.bancoz.lineaverde.commons.domain.Cdt;
import io.micrometer.core.annotation.Timed;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * Controlador REST del endpoint de apertura de CDT.
 * Punto de instrumentación P3 (docs/experimento_asr.md §5.2).
 *
 * Regla crítica: el 202 NO espera al core. Retorna tras INSERT cdt+outbox.
 * Cualquier llamada al core en este path es un bug arquitectónico.
 */
@RestController
@RequestMapping("/v1/cdt")
public class CdtController {

    private static final Logger log = LoggerFactory.getLogger(CdtController.class);

    /** País de esta instancia — configurado por env LV_PAIS=pe|mx|co. */
    @Value("${app.pais}")
    private String paisInstancia;

    private final CdtService cdtService;

    public CdtController(CdtService cdtService) {
        this.cdtService = cdtService;
    }

    /**
     * POST /v1/cdt — Apertura de CDT digital.
     *
     * @param xPais Header X-Pais enrutado por Kong. Debe coincidir con LV_PAIS de esta instancia.
     * @param req   Payload con clienteId, monto, plazoDias, tasaAnual.
     * @return 202 Accepted con { cdtId: UUID }
     *
     * Instrumentación P3: @Timed mide la duración de todo el handler, incluida la transacción DB.
     */
    @PostMapping
    @Timed(value = "cdt_open_handler_duration_seconds",
           description = "Duración del handler POST /v1/cdt — P3 experimento ASR-1",
           extraTags = {"endpoint", "open_cdt"})
    public ResponseEntity<OpenCdtResponse> openCdt(
            @RequestHeader(value = "X-Pais", required = false) String xPais,
            @Valid @RequestBody OpenCdtRequest req) {

        // Validar que el request llega al país correcto
        // (Kong ya enruta por header, pero validamos para detectar misconfiguraciones)
        if (xPais != null && !xPais.equalsIgnoreCase(paisInstancia)) {
            log.warn("Request con X-Pais={} llegó a instancia de país={}. Posible mis-routing de Kong.",
                     xPais, paisInstancia);
        }

        log.debug("Abriendo CDT: clienteId={}, monto={}, plazoDias={}, pais={}",
                  req.clienteId(), req.monto(), req.plazoDias(), paisInstancia);

        Cdt cdt = cdtService.openCdt(req.clienteId(), req.monto(), req.plazoDias(), req.tasaAnual());

        log.info("CDT creado: id={}, pais={}", cdt.getId(), cdt.getPais());
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(new OpenCdtResponse(cdt.getId()));
    }
}

package co.bancoz.lineaverde.cdtpais.domain;

import co.bancoz.lineaverde.cdtpais.persistence.CdtRepository;
import co.bancoz.lineaverde.cdtpais.persistence.OutboxRepository;
import co.bancoz.lineaverde.commons.domain.Cdt;
import co.bancoz.lineaverde.commons.events.CdtAbiertoEvent;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/**
 * Servicio de dominio para apertura de CDT.
 * Corresponde al componente CDTXPais en el diagrama de clases.
 *
 * Regla crítica: @Transactional garantiza que INSERT cdt + INSERT outbox
 * ocurran atómicamente. Si uno falla, ambos hacen rollback.
 * NO hay llamadas al core en este método — eso viola ASR-1 y la arquitectura.
 *
 * Instrumentación P4 (docs/experimento_asr.md §5.2):
 *   Timer "cdt_db_write_duration_seconds" mide la transacción DB completa.
 */
@Service
public class CdtService {

    private static final Logger log = LoggerFactory.getLogger(CdtService.class);

    /** País de esta instancia — env LV_PAIS, seteado en application.yml como ${LV_PAIS}. */
    @Value("${app.pais}")
    private String pais;

    private final CdtRepository cdtRepository;
    private final OutboxRepository outboxRepository;
    private final Timer dbWriteTimer;

    public CdtService(CdtRepository cdtRepository,
                      OutboxRepository outboxRepository,
                      MeterRegistry meterRegistry) {
        this.cdtRepository   = cdtRepository;
        this.outboxRepository = outboxRepository;
        // P4: Timer para medir duración de la transacción DB
        this.dbWriteTimer = Timer.builder("cdt_db_write_duration_seconds")
                .description("Duración INSERT cdt + outbox en la misma transacción — P4 experimento ASR-1")
                .register(meterRegistry);
    }

    /**
     * Abre un CDT: INSERT atómico en cdt.cdt + cdt.outbox_cdt_eventos.
     *
     * @return Cdt creado con ID asignado.
     * Contrato: retorna en < 200 ms sin carga (F4.T-5, F4.AC-3).
     */
    @Transactional
    public Cdt openCdt(String clienteId, BigDecimal monto, int plazoDias, BigDecimal tasaAnual) {
        Cdt cdt = new Cdt(UUID.randomUUID(), pais, clienteId, monto, plazoDias, tasaAnual);

        // Mide la escritura DB (P4)
        dbWriteTimer.record(() -> {
            cdtRepository.insert(cdt);

            CdtAbiertoEvent event = new CdtAbiertoEvent(
                    cdt.getId(),
                    cdt.getPais(),
                    cdt.getClienteId(),
                    cdt.getMonto(),
                    cdt.getPlazoDias(),
                    cdt.getTasaAnual(),
                    Instant.now()
            );
            outboxRepository.insertEvent(cdt.getId(), event);
        });

        return cdt;
    }
}

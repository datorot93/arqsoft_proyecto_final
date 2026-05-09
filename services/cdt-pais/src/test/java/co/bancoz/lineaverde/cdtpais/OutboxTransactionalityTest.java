package co.bancoz.lineaverde.cdtpais;

import co.bancoz.lineaverde.cdtpais.domain.CdtService;
import co.bancoz.lineaverde.cdtpais.persistence.CdtRepository;
import co.bancoz.lineaverde.cdtpais.persistence.OutboxRepository;
import co.bancoz.lineaverde.commons.domain.Cdt;
import co.bancoz.lineaverde.commons.events.CdtAbiertoEvent;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios de transaccionalidad del patrón Outbox.
 *
 * Verifica el criterio F4.AC-2 y F4.T-6:
 *   - Si el insert de outbox falla DESPUÉS del insert de cdt, la transacción
 *     DEBE hacer rollback completo (comportamiento garantizado por @Transactional).
 *
 * Nota: la garantía real de rollback ACID requiere un test de integración con
 * Postgres real (ver tests/f4/VERIFICACION.md). Este test verifica el flujo nominal
 * y el comportamiento de excepción a nivel de unidad.
 *
 * El test de integración completo se ejecuta con H2 (modo compatibility PostgreSQL)
 * o se valida en runtime con el gate F4.T-6.
 */
@ExtendWith(MockitoExtension.class)
class OutboxTransactionalityTest {

    @Mock
    private CdtRepository cdtRepository;

    @Mock
    private OutboxRepository outboxRepository;

    private CdtService cdtService;

    @BeforeEach
    void setUp() {
        var meterRegistry = new SimpleMeterRegistry();
        cdtService = new CdtService(cdtRepository, outboxRepository, meterRegistry);
        // Simular env LV_PAIS=pe (en test no hay Spring context completo)
        ReflectionTestUtils.setField(cdtService, "pais", "pe");
    }

    @Test
    void openCdt_flujoNominal_insertaCdtYOutbox() {
        // Arrange: mocks no lanzan excepción por defecto

        // Act
        Cdt resultado = cdtService.openCdt(
                "cli-001",
                new BigDecimal("1000.00"),
                90,
                new BigDecimal("0.0850")
        );

        // Assert
        assertThat(resultado).isNotNull();
        assertThat(resultado.getId()).isNotNull();
        assertThat(resultado.getPais()).isEqualTo("pe");
        assertThat(resultado.getClienteId()).isEqualTo("cli-001");
        assertThat(resultado.getMonto()).isEqualByComparingTo("1000.00");

        // Verificar que ambos inserts fueron llamados
        verify(cdtRepository, times(1)).insert(any(Cdt.class));
        verify(outboxRepository, times(1)).insertEvent(any(UUID.class), any(CdtAbiertoEvent.class));
    }

    @Test
    void openCdt_fallaEnOutbox_propagaExcepcion() {
        // Arrange: outbox falla después del insert de cdt
        doThrow(new RuntimeException("Error simulado en outbox — rollback esperado"))
                .when(outboxRepository).insertEvent(any(), any());

        // Act + Assert: la excepción se propaga (Spring @Transactional hará rollback)
        assertThatThrownBy(() -> cdtService.openCdt(
                "cli-001",
                new BigDecimal("500.00"),
                30,
                new BigDecimal("0.07")
        ))
                .isInstanceOf(RuntimeException.class)
                .hasMessageContaining("Error simulado en outbox");

        // cdtRepository.insert fue llamado (rollback lo deshará en transacción real)
        verify(cdtRepository, times(1)).insert(any(Cdt.class));
    }

    @Test
    void openCdt_fallaEnCdt_outboxNoSeInvoca() {
        // Arrange: cdt falla antes de llegar al outbox
        doThrow(new RuntimeException("Error en cdt insert — outbox NO debe llamarse"))
                .when(cdtRepository).insert(any());

        // Act + Assert
        assertThatThrownBy(() -> cdtService.openCdt(
                "cli-002",
                new BigDecimal("2000.00"),
                180,
                new BigDecimal("0.09")
        ))
                .isInstanceOf(RuntimeException.class);

        // Si cdt falla, outbox NUNCA debe ser llamado
        verify(outboxRepository, never()).insertEvent(any(), any());
    }

    @Test
    void openCdt_generaUuidV4Diferente_cadaLlamada() {
        // Verificar que cada llamada genera un ID único (no hay estado compartido)
        Cdt cdt1 = cdtService.openCdt("cli-001", BigDecimal.TEN, 30, new BigDecimal("0.05"));
        Cdt cdt2 = cdtService.openCdt("cli-001", BigDecimal.TEN, 30, new BigDecimal("0.05"));

        assertThat(cdt1.getId()).isNotEqualTo(cdt2.getId());
    }
}

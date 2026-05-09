package co.bancoz.lineaverde.acl;

import co.bancoz.lineaverde.acl.api.ReservarRequest;
import co.bancoz.lineaverde.acl.api.ReservarResponse;
import co.bancoz.lineaverde.acl.client.CoreClient;
import co.bancoz.lineaverde.acl.client.ResilientCoreClient;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.web.client.HttpServerErrorException;

import java.math.BigDecimal;
import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios del comportamiento del CircuitBreaker del ACL.
 *
 * Verifica F4.AC-5 (CB abre con 50%+ errores) y F4.AC-6 (CB se recupera).
 *
 * Nota: en este test el CB se configura programáticamente para poder controlarlo
 * de forma determinista en el test. La configuración de producción está en
 * application.yml y se aplica via Spring Boot auto-configuration de Resilience4j.
 *
 * El test de integración completo (T-7, T-8) requiere cluster con servicios desplegados.
 */
@ExtendWith(MockitoExtension.class)
class CircuitBreakerBehaviorTest {

    @Mock
    private CoreClient coreClient;

    private CircuitBreaker circuitBreaker;
    private CircuitBreakerRegistry registry;

    private static final ReservarRequest SAMPLE_REQUEST = new ReservarRequest(
            UUID.randomUUID(),
            "cli-001",
            new BigDecimal("1000.00"),
            90,
            new BigDecimal("0.085"),
            "pe"
    );

    @BeforeEach
    void setUp() {
        // CB programático con ventana de 10 calls (más rápido en tests)
        CircuitBreakerConfig config = CircuitBreakerConfig.custom()
                .slidingWindowType(CircuitBreakerConfig.SlidingWindowType.COUNT_BASED)
                .slidingWindowSize(10)
                .failureRateThreshold(50.0f)
                .waitDurationInOpenState(Duration.ofSeconds(1)) // 1s para tests (30s en prod)
                .permittedNumberOfCallsInHalfOpenState(3)
                .build();

        registry = CircuitBreakerRegistry.of(config);
        circuitBreaker = registry.circuitBreaker("core-test");
    }

    @Test
    void circuitBreaker_estadoInicial_cerrado() {
        assertThat(circuitBreaker.getState()).isEqualTo(CircuitBreaker.State.CLOSED);
    }

    @Test
    void circuitBreaker_abreConMasDe50PorCientoDeErrores() {
        // Simular 6 fallos y 4 éxitos (60% fallos > 50% threshold)
        for (int i = 0; i < 6; i++) {
            circuitBreaker.onError(0, java.util.concurrent.TimeUnit.MILLISECONDS,
                    new HttpServerErrorException(org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE));
        }
        for (int i = 0; i < 4; i++) {
            circuitBreaker.onSuccess(0, java.util.concurrent.TimeUnit.MILLISECONDS);
        }

        // Con ventana de 10 calls completada: 60% > 50% → debe abrir
        assertThat(circuitBreaker.getState()).isEqualTo(CircuitBreaker.State.OPEN);
    }

    @Test
    void circuitBreaker_noBriaConMenos50PorCientoDeErrores() {
        // Simular 4 fallos y 6 éxitos (40% fallos < 50% threshold)
        for (int i = 0; i < 4; i++) {
            circuitBreaker.onError(0, java.util.concurrent.TimeUnit.MILLISECONDS,
                    new HttpServerErrorException(org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE));
        }
        for (int i = 0; i < 6; i++) {
            circuitBreaker.onSuccess(0, java.util.concurrent.TimeUnit.MILLISECONDS);
        }

        assertThat(circuitBreaker.getState()).isEqualTo(CircuitBreaker.State.CLOSED);
    }

    @Test
    void circuitBreaker_transicionaHalfOpenDespuesDeWait() throws InterruptedException {
        // Abrir el CB
        for (int i = 0; i < 10; i++) {
            circuitBreaker.onError(0, java.util.concurrent.TimeUnit.MILLISECONDS,
                    new RuntimeException("error"));
        }
        assertThat(circuitBreaker.getState()).isEqualTo(CircuitBreaker.State.OPEN);

        // Esperar el waitDurationInOpenState (1s en test)
        Thread.sleep(1100);
        // Forzar transición a HALF_OPEN haciendo un intento
        circuitBreaker.tryAcquirePermission();

        assertThat(circuitBreaker.getState())
                .isIn(CircuitBreaker.State.HALF_OPEN, CircuitBreaker.State.CLOSED);
    }

    @Test
    void resilientCoreClient_fallbackRetornaPendiente() {
        // Test de unidad del método fallback directamente (sin Spring AOP).
        // La integración con CB+Retry+Bulkhead se verifica en los tests de integración
        // del gate F4.T-7 y F4.T-8 con cluster corriendo.
        ResilientCoreClient resilientClient = new ResilientCoreClient(coreClient);

        ReservarResponse fallbackResponse = resilientClient.reservarFallback(
                SAMPLE_REQUEST,
                new RuntimeException("core caído")
        );

        assertThat(fallbackResponse.status()).isEqualTo("PENDIENTE");
        assertThat(fallbackResponse.cdtId()).isEqualTo(SAMPLE_REQUEST.cdtId());
        assertThat(fallbackResponse.mensaje()).contains("Core no disponible");
    }
}

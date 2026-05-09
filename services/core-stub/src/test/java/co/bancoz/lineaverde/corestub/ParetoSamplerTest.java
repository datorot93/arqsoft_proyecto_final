package co.bancoz.lineaverde.corestub;

import co.bancoz.lineaverde.corestub.distributions.ParetoSampler;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Tests unitarios del ParetoSampler.
 * Verifica:
 *   1. Media empírica ≈ media teórica con tolerancia 5% (10000 muestras).
 *   2. Todos los valores son ≥ xm (= 80 ms) — propiedad de Pareto.
 *   3. Reproducibilidad con semilla fija.
 *
 * Media teórica de Pareto(xm=80, α=2.5):
 *   E[X] = xm × α / (α - 1) = 80 × 2.5 / 1.5 ≈ 133.33 ms
 *
 * Con 10000 muestras y tolerancia 5% (±6.67 ms), el test es estable.
 */
class ParetoSamplerTest {

    @Test
    void sample_mediaEmpiricaCercanaAMediaTeorica() {
        // Seed fijo para reproducibilidad
        ParetoSampler sampler = new ParetoSampler(42L);

        int n = 10_000;
        long sum = 0;
        for (int i = 0; i < n; i++) {
            sum += sampler.sample();
        }
        double mediaEmpirica = (double) sum / n;

        // Media teórica: 80 × 2.5 / (2.5 - 1) = 133.33 ms
        double mediaTeorica = sampler.getScale() * sampler.getShape() / (sampler.getShape() - 1);
        double tolerancia = mediaTeorica * 0.05; // 5%

        assertThat(mediaEmpirica)
                .as("Media empírica %.2f debe ser %.2f ± %.2f (5%%)", mediaEmpirica, mediaTeorica, tolerancia)
                .isBetween(mediaTeorica - tolerancia, mediaTeorica + tolerancia);
    }

    @Test
    void sample_todosLosValoresSonMayoresIgualQueXm() {
        ParetoSampler sampler = new ParetoSampler(123L);
        double xm = sampler.getScale(); // 80.0

        for (int i = 0; i < 1000; i++) {
            long valor = sampler.sample();
            assertThat(valor)
                    .as("Pareto sample debe ser >= xm=%.0f ms", xm)
                    .isGreaterThanOrEqualTo((long) xm);
        }
    }

    @Test
    void sample_reproducibleConSemillaFija() {
        // La misma semilla debe producir la misma secuencia
        ParetoSampler sampler1 = new ParetoSampler(999L);
        ParetoSampler sampler2 = new ParetoSampler(999L);

        for (int i = 0; i < 100; i++) {
            assertThat(sampler1.sample()).isEqualTo(sampler2.sample());
        }
    }

    @Test
    void sample_truncadoAMaximo10000ms() {
        // Con cualquier semilla, ningún valor debe superar el tope
        ParetoSampler sampler = new ParetoSampler(1L);
        for (int i = 0; i < 10_000; i++) {
            assertThat(sampler.sample()).isLessThanOrEqualTo(10_000L);
        }
    }
}

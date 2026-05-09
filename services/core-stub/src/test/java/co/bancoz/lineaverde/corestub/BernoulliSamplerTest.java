package co.bancoz.lineaverde.corestub;

import co.bancoz.lineaverde.corestub.distributions.BernoulliSampler;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Tests unitarios del BernoulliSampler.
 * Verifica:
 *   1. Con p=0.0 nunca falla.
 *   2. Con p=1.0 siempre falla.
 *   3. Con p=0.6, ratio empírico ≈ 0.6 ± 0.05 (10000 muestras).
 *   4. Con p=0.3, ratio empírico ≈ 0.3 ± 0.05 (10000 muestras).
 */
class BernoulliSamplerTest {

    private final BernoulliSampler sampler = new BernoulliSampler();

    @Test
    void shouldFail_conP0_nuncaFalla() {
        for (int i = 0; i < 1000; i++) {
            assertThat(sampler.shouldFail(0.0)).isFalse();
        }
    }

    @Test
    void shouldFail_conP1_siempreFalla() {
        for (int i = 0; i < 1000; i++) {
            assertThat(sampler.shouldFail(1.0)).isTrue();
        }
    }

    @Test
    void shouldFail_conP06_ratioEmpiricoCorrect() {
        int n = 10_000;
        int fallos = 0;
        for (int i = 0; i < n; i++) {
            if (sampler.shouldFail(0.6)) fallos++;
        }
        double ratioEmpírico = (double) fallos / n;

        assertThat(ratioEmpírico)
                .as("Bernoulli(0.6): ratio empírico %.4f debe ser 0.6 ± 0.05", ratioEmpírico)
                .isBetween(0.55, 0.65);
    }

    @Test
    void shouldFail_conP03_ratioEmpiricoCorrect() {
        int n = 10_000;
        int fallos = 0;
        for (int i = 0; i < n; i++) {
            if (sampler.shouldFail(0.3)) fallos++;
        }
        double ratioEmpírico = (double) fallos / n;

        assertThat(ratioEmpírico)
                .as("Bernoulli(0.3): ratio empírico %.4f debe ser 0.3 ± 0.05", ratioEmpírico)
                .isBetween(0.25, 0.35);
    }

    @Test
    void shouldFail_valoresLimite() {
        // Verificar que p negativa y p > 1 se manejan bien
        assertThat(sampler.shouldFail(-0.1)).isFalse();
        assertThat(sampler.shouldFail(1.1)).isTrue();
    }
}

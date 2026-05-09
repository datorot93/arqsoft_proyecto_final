package co.bancoz.lineaverde.corestub.distributions;

import org.apache.commons.math3.distribution.ParetoDistribution;
import org.apache.commons.math3.random.JDKRandomGenerator;
import org.apache.commons.math3.random.RandomGenerator;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Muestreador de latencia con distribución Pareto Tipo II.
 *
 * Parámetros según spec F4 (docs/experimento_asr.md §4 — modelo estocástico):
 *   - xm (scale) = 80 ms — latencia mínima del core
 *   - α (shape) = 2.5 — heavy tail moderado
 *
 * Distribución: Pareto(xm=80, α=2.5)
 *   E[X] = xm × α / (α - 1) = 80 × 2.5 / 1.5 ≈ 133 ms (media teórica)
 *   P95 teórico ≈ 80 × (1/(1-0.95))^(1/2.5) ≈ 331 ms
 *
 * Apache Commons Math ParetoDistribution usa (scale, shape) donde:
 *   scale = xm (mínimo)
 *   shape = α
 *
 * La semilla SEED es configurable por env para reproducibilidad en tests.
 * En producción del experimento, no setar SEED para aleatoriedad real.
 *
 * El valor muestreado se trunca a max 10 000 ms para evitar latencias absurdas
 * (cola de Pareto puede producir valores muy grandes).
 */
@Component
public class ParetoSampler {

    private static final double SCALE = 80.0;  // xm = 80 ms
    private static final double SHAPE = 2.5;   // α = 2.5
    private static final long MAX_LATENCY_MS = 10_000L;

    private final ParetoDistribution distribution;

    public ParetoSampler(@Value("${stub.seed:-1}") long seed) {
        RandomGenerator rng;
        if (seed >= 0) {
            rng = new JDKRandomGenerator((int) seed);
        } else {
            rng = new JDKRandomGenerator();
            rng.setSeed(System.nanoTime());
        }
        this.distribution = new ParetoDistribution(rng, SCALE, SHAPE);
    }

    /**
     * Devuelve una latencia en milisegundos muestreada de Pareto(80, 2.5).
     * El resultado está en el rango [80, 10000] ms.
     */
    public long sample() {
        double sample = distribution.sample();
        // Pareto con scale=80 siempre produce valores >= 80
        return Math.min((long) Math.round(sample), MAX_LATENCY_MS);
    }

    public double getScale() { return SCALE; }
    public double getShape() { return SHAPE; }
}

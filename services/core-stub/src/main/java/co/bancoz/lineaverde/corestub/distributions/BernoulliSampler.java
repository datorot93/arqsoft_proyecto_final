package co.bancoz.lineaverde.corestub.distributions;

import org.springframework.stereotype.Component;

import java.util.Random;

/**
 * Muestreador de errores con distribución Bernoulli.
 * Un ensayo de Bernoulli(p) retorna true con probabilidad p (= "fallo del core").
 *
 * Parámetros configurables:
 *   - p por header X-Stub-Error-Rate en cada request (override por call).
 *   - p por defecto desde env STUB_ERROR_RATE_DEFAULT (default 0.0 = sin errores).
 *
 * Thread-safe: Random estándar no es thread-safe bajo concurrencia alta.
 * Con virtual threads y muchas peticiones simultáneas, se usa ThreadLocalRandom
 * para garantizar correctitud sin contención de monitor.
 */
@Component
public class BernoulliSampler {

    /**
     * Determina si el ensayo actual resulta en fallo.
     *
     * @param p Probabilidad de fallo [0.0, 1.0]. 0.0 = sin errores, 1.0 = todos fallan.
     * @return true si la request debe responder con error (503).
     */
    public boolean shouldFail(double p) {
        if (p <= 0.0) return false;
        if (p >= 1.0) return true;
        // ThreadLocalRandom para evitar contención en virtual threads
        return java.util.concurrent.ThreadLocalRandom.current().nextDouble() < p;
    }
}

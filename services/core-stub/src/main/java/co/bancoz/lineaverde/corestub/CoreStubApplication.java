package co.bancoz.lineaverde.corestub;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Stub del CoreBancoZ para el experimento ASR-1/ASR-2.
 * Simula el comportamiento estocástico del core bancario real:
 *   - Latencia: distribución Pareto Tipo II (xm=80ms, α=2.5)
 *   - Errores: distribución Bernoulli con p configurable
 *
 * DESVIACIÓN DOCUMENTADA: el spec original indica WebFlux, pero el agente
 * spring-boot-developer prohíbe WebFlux y exige coherencia con virtual threads.
 * Se usa Spring Web servlet con spring.threads.virtual.enabled=true.
 * El comportamiento observable (latencia, errores) es idéntico.
 */
@SpringBootApplication
public class CoreStubApplication {

    public static void main(String[] args) {
        SpringApplication.run(CoreStubApplication.class, args);
    }
}

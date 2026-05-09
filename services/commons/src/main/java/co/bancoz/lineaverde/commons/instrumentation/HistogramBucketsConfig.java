package co.bancoz.lineaverde.commons.instrumentation;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.Meter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.config.MeterFilter;
import io.micrometer.core.instrument.distribution.DistributionStatisticConfig;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * Configuración de buckets de histograma para Micrometer.
 *
 * Lee los buckets desde el volumen montado del ConfigMap histogram-buckets
 * (publicado por F3 en el namespace observabilidad; replicado en linea-verde,
 * acl y core-stub como ConfigMap espejo por limitación de K8s: los ConfigMaps
 * no son cross-namespace).
 *
 * Ruta del archivo: /etc/histogram-buckets/buckets_seconds.json
 * Variable de entorno HISTOGRAM_BUCKETS_PATH sobreescribe la ruta (útil en tests).
 *
 * Si el archivo no existe (entorno de test unitario sin volumen montado),
 * usa los 13 valores definidos en §5.1 del experimento como fallback y emite
 * un WARN visible. El código de producción SIEMPRE monta el ConfigMap.
 *
 * Aplica a todas las métricas cuyo nombre termina en "_duration_seconds".
 */
public class HistogramBucketsConfig {

    private static final Logger log = LoggerFactory.getLogger(HistogramBucketsConfig.class);

    // Buckets por defecto (fallback) — §5.1 experimento_asr.md
    private static final double[] FALLBACK_BUCKETS = {
        0.01, 0.025, 0.05, 0.1, 0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 2.5, 5.0, 10.0
    };

    private static final String DEFAULT_PATH = "/etc/histogram-buckets/buckets_seconds.json";

    private final double[] buckets;

    public HistogramBucketsConfig() {
        this.buckets = loadBuckets();
    }

    private double[] loadBuckets() {
        String path = System.getenv().getOrDefault("HISTOGRAM_BUCKETS_PATH", DEFAULT_PATH);
        try {
            String content = Files.readString(Path.of(path));
            ObjectMapper mapper = new ObjectMapper();
            List<Double> list = mapper.readValue(content, new TypeReference<List<Double>>() {});
            double[] result = list.stream().mapToDouble(Double::doubleValue).toArray();
            log.info("Buckets de histograma cargados desde ConfigMap: {} ({} buckets)", path, result.length);
            return result;
        } catch (IOException e) {
            log.warn("No se pudo leer {} (¿running en test sin ConfigMap montado?). " +
                     "Usando fallback de {} buckets hardcoded de §5.1. " +
                     "EN PRODUCCIÓN ESTO ES UN ERROR — verificar montaje del ConfigMap.",
                     path, FALLBACK_BUCKETS.length);
            return FALLBACK_BUCKETS.clone();
        }
    }

    /**
     * Registra el MeterFilter en el MeterRegistry.
     * Llamar desde @PostConstruct o desde @Bean de configuración.
     *
     * Aplica DistributionStatisticConfig con SLOs (buckets explícitos) a todas las
     * métricas cuyo nombre termina en "_duration_seconds". Esto incluye:
     *   - cdt_open_handler_duration_seconds  (P3 — cdt-pais)
     *   - cdt_db_write_duration_seconds       (P4 — cdt-pais)
     *   - core_call_duration_seconds          (P6 — acl)
     */
    public void registerMeterFilter(MeterRegistry registry) {
        final double[] resolvedBuckets = this.buckets;
        registry.config().meterFilter(new MeterFilter() {
            @Override
            public DistributionStatisticConfig configure(Meter.Id id, DistributionStatisticConfig config) {
                if (id.getName().endsWith("_duration_seconds")) {
                    return DistributionStatisticConfig.builder()
                            .serviceLevelObjectives(resolvedBuckets)
                            .percentilesHistogram(false)
                            .build()
                            .merge(config);
                }
                return config;
            }
        });
        log.info("MeterFilter de histograma registrado ({} buckets)", resolvedBuckets.length);
    }

    public double[] getBuckets() {
        return buckets.clone();
    }
}

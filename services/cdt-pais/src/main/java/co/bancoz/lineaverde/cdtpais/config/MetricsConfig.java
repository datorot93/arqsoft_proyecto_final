package co.bancoz.lineaverde.cdtpais.config;

import co.bancoz.lineaverde.commons.instrumentation.HistogramBucketsConfig;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PostConstruct;
import org.springframework.context.annotation.Configuration;

/**
 * Configuración de Micrometer para cdt-pais.
 * Lee los buckets desde el ConfigMap montado y registra el MeterFilter global.
 * El ConfigMap (histogram-buckets) es replicado en el namespace linea-verde
 * como espejo del original en observabilidad (limitación K8s: CMs no cross-namespace).
 */
@Configuration
public class MetricsConfig {

    private final MeterRegistry meterRegistry;
    private final HistogramBucketsConfig bucketsConfig;

    public MetricsConfig(MeterRegistry meterRegistry) {
        this.meterRegistry = meterRegistry;
        this.bucketsConfig = new HistogramBucketsConfig();
    }

    @PostConstruct
    public void configureBuckets() {
        bucketsConfig.registerMeterFilter(meterRegistry);
    }
}

package co.bancoz.lineaverde.acl.config;

import co.bancoz.lineaverde.commons.instrumentation.HistogramBucketsConfig;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PostConstruct;
import org.springframework.context.annotation.Configuration;

/**
 * Configuración de Micrometer para el ACL.
 * Registra el MeterFilter con buckets del ConfigMap.
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

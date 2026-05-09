package co.bancoz.lineaverde.acl.config;

import co.bancoz.lineaverde.commons.instrumentation.HistogramBucketsConfig;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.boot.actuate.autoconfigure.metrics.MeterRegistryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Configuración de Micrometer para el ACL.
 * Aplica el MeterFilter vía MeterRegistryCustomizer para que se aplique ANTES
 * de que cualquier Timer sea creado.
 */
@Configuration
public class MetricsConfig {

    @Bean
    public MeterRegistryCustomizer<MeterRegistry> histogramBucketsCustomizer() {
        HistogramBucketsConfig bucketsConfig = new HistogramBucketsConfig();
        return registry -> bucketsConfig.registerMeterFilter(registry);
    }
}

package co.bancoz.lineaverde.cdtpais.config;

import co.bancoz.lineaverde.commons.instrumentation.HistogramBucketsConfig;
import io.micrometer.core.aop.TimedAspect;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.boot.actuate.autoconfigure.metrics.MeterRegistryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Configuración de Micrometer para cdt-pais.
 * Registra el MeterFilter de buckets ANTES de que cualquier Timer sea creado.
 *
 * IMPORTANTE: el MeterFilter debe aplicarse vía MeterRegistryCustomizer (no
 * @PostConstruct) para garantizar que esté activo antes de cualquier @Timed.
 * Spring Boot ejecuta los Customizer al construir el MeterRegistry, mientras
 * que @PostConstruct corre después — riesgo de meters creados con buckets default.
 */
@Configuration
public class MetricsConfig {

    /**
     * Aplica el MeterFilter al MeterRegistry durante su construcción.
     * Garantiza que TODOS los Timers (incluidos los creados por TimedAspect)
     * tengan los SLO buckets del experimento.
     */
    @Bean
    public MeterRegistryCustomizer<MeterRegistry> histogramBucketsCustomizer() {
        HistogramBucketsConfig bucketsConfig = new HistogramBucketsConfig();
        return registry -> bucketsConfig.registerMeterFilter(registry);
    }

    /**
     * TimedAspect: requerido para que la anotación @Timed (Micrometer) funcione.
     * Sin este bean, @Timed es inerte y no registra Timers.
     * El starter spring-boot-starter-aop debe estar en el classpath.
     */
    @Bean
    public TimedAspect timedAspect(MeterRegistry registry) {
        return new TimedAspect(registry);
    }
}

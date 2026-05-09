package co.bancoz.lineaverde.cdtpais.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Configuración adicional del datasource y de beans de infraestructura.
 * HikariCP se configura en application.yml (maximum-pool-size=20, etc.).
 */
@Configuration
public class DataSourceConfig {

    /**
     * ObjectMapper con soporte para Java Time (Instant, LocalDate, etc.)
     * Usado por OutboxRepository para serializar CdtAbiertoEvent a JSON.
     */
    @Bean
    public ObjectMapper objectMapper() {
        return new ObjectMapper()
                .registerModule(new JavaTimeModule());
    }
}

package co.bancoz.lineaverde.cdtpais;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Punto de entrada del servicio CDTXPais.
 * Una sola imagen — país configurado por env LV_PAIS=pe|mx|co.
 * Virtual threads habilitados en application.yml: spring.threads.virtual.enabled=true
 */
@SpringBootApplication
public class CdtPaisApplication {

    public static void main(String[] args) {
        SpringApplication.run(CdtPaisApplication.class, args);
    }
}

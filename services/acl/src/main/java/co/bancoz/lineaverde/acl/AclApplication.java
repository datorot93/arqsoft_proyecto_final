package co.bancoz.lineaverde.acl;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Punto de entrada del servicio ACL (Anti-Corruption Layer).
 * Implementa el subsistema Integracion: AdaptadorCore + CircuitBreaker.
 * Es el ÚNICO punto de salida hacia core-stub (reforzado por NetworkPolicies en F1).
 */
@SpringBootApplication
public class AclApplication {

    public static void main(String[] args) {
        SpringApplication.run(AclApplication.class, args);
    }
}

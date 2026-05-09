package co.bancoz.lineaverde.commons.domain;

/**
 * Estados del ciclo de vida de un CDT.
 * Diagrama de clases: CDT.estado. Persistido como VARCHAR(20) en cdt.cdt.
 * PENDIENTE → ACTIVO (ACL confirma reserva en core)
 * ACTIVO → CONGELADO (DetectorFraude en F8)
 */
public enum EstadoCdt {
    PENDIENTE,
    ACTIVO,
    CONGELADO
}

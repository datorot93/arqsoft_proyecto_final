package co.bancoz.lineaverde.acl.api;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;
import java.util.UUID;

/**
 * DTO de entrada para POST /acl/reservar.
 * Recibido desde cdt-pais (futuro: outbox-dispatcher en Opción B).
 * En la arquitectura actual (Opción A síncrona), cdt-pais llama directamente al ACL.
 */
public record ReservarRequest(
        @NotNull UUID cdtId,
        @NotBlank String clienteId,
        @NotNull BigDecimal monto,
        int plazoDias,
        @NotNull BigDecimal tasaAnual,
        @NotBlank String pais
) {}

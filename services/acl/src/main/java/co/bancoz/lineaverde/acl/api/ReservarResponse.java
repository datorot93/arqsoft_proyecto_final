package co.bancoz.lineaverde.acl.api;

import java.util.UUID;

/**
 * DTO de respuesta del ACL hacia el caller (cdt-pais u outbox-dispatcher).
 */
public record ReservarResponse(
        UUID cdtId,
        String status,
        String mensaje
) {}

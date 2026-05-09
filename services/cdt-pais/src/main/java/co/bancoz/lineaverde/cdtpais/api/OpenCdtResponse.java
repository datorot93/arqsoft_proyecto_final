package co.bancoz.lineaverde.cdtpais.api;

import java.util.UUID;

/**
 * DTO de respuesta para POST /v1/cdt.
 * HTTP 202 Accepted con el UUID del CDT creado.
 */
public record OpenCdtResponse(UUID cdtId) {}

package co.bancoz.lineaverde.cdtpais.api;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;

/**
 * DTO de entrada para POST /v1/cdt.
 * Validación mínima: campos requeridos y rangos. KYC ya fue hecho en onboarding (§3.2).
 *
 * <p>{@code @JsonIgnoreProperties(ignoreUnknown=true)} es necesario porque records
 * con Jackson 2.x rechazan campos desconocidos por default. F5 envía un campo
 * `metadata` con padding ASCII para alcanzar el tamaño Lognormal del documento
 * maestro §4.3 — descartar el campo es la lectura correcta para un endpoint
 * tolerante.</p>
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record OpenCdtRequest(

        @NotBlank(message = "clienteId es requerido")
        String clienteId,

        @NotNull(message = "monto es requerido")
        @DecimalMin(value = "0.01", message = "monto debe ser positivo")
        BigDecimal monto,

        @Min(value = 1, message = "plazoDias debe ser positivo")
        int plazoDias,

        @NotNull(message = "tasaAnual es requerida")
        @DecimalMin(value = "0.0", message = "tasaAnual no puede ser negativa")
        BigDecimal tasaAnual
) {}

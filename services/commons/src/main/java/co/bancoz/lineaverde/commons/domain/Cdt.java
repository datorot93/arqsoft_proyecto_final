package co.bancoz.lineaverde.commons.domain;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/**
 * Entidad de dominio CDT — mapeada a la tabla cdt.cdt.
 * Schema definido en infra/sql/01-init-cdt.sql (F2, no modificar).
 * Corresponde al componente CDTXPais del diagrama de clases.
 */
public class Cdt {

    private final UUID id;
    /** País en formato ISO-3166-1 alpha-2: pe, mx, co. Persistido y usado como label de métricas. */
    private final String pais;
    private final String clienteId;
    private final BigDecimal monto;
    private final int plazoDias;
    private final BigDecimal tasaAnual;
    private EstadoCdt estado;
    private final Instant createdAt;
    private Instant updatedAt;

    public Cdt(UUID id,
               String pais,
               String clienteId,
               BigDecimal monto,
               int plazoDias,
               BigDecimal tasaAnual) {
        this.id        = id;
        this.pais      = pais;
        this.clienteId = clienteId;
        this.monto     = monto;
        this.plazoDias = plazoDias;
        this.tasaAnual = tasaAnual;
        this.estado    = EstadoCdt.PENDIENTE;
        this.createdAt = Instant.now();
        this.updatedAt = this.createdAt;
    }

    // --- getters ---

    public UUID getId()             { return id; }
    public String getPais()         { return pais; }
    public String getClienteId()    { return clienteId; }
    public BigDecimal getMonto()    { return monto; }
    public int getPlazoDias()       { return plazoDias; }
    public BigDecimal getTasaAnual(){ return tasaAnual; }
    public EstadoCdt getEstado()    { return estado; }
    public Instant getCreatedAt()   { return createdAt; }
    public Instant getUpdatedAt()   { return updatedAt; }

    public void activar() {
        this.estado    = EstadoCdt.ACTIVO;
        this.updatedAt = Instant.now();
    }

    public void congelar() {
        this.estado    = EstadoCdt.CONGELADO;
        this.updatedAt = Instant.now();
    }
}

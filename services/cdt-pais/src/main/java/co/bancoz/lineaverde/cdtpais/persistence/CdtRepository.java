package co.bancoz.lineaverde.cdtpais.persistence;

import co.bancoz.lineaverde.commons.domain.Cdt;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

/**
 * Repositorio de acceso a cdt.cdt.
 * Usa JdbcTemplate directamente (más rápido que JPA para INSERTs en el critical path).
 * Schema definido en infra/sql/01-init-cdt.sql — NO modificar.
 */
@Repository
public class CdtRepository {

    private final JdbcTemplate jdbc;

    public CdtRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * Inserta un CDT nuevo en la tabla cdt.cdt.
     * Todos los campos son obligatorios; pais se toma del objeto Cdt (= LV_PAIS de esta instancia).
     */
    public void insert(Cdt cdt) {
        jdbc.update("""
                INSERT INTO cdt.cdt
                  (id, pais, cliente_id, monto, plazo_dias, tasa_anual, estado, created_at, updated_at)
                VALUES
                  (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                cdt.getId(),
                cdt.getPais(),
                cdt.getClienteId(),
                cdt.getMonto(),
                cdt.getPlazoDias(),
                cdt.getTasaAnual(),
                cdt.getEstado().name(),
                cdt.getCreatedAt(),
                cdt.getUpdatedAt()
        );
    }
}

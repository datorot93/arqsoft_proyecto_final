# Módulo db — Base de datos parametrizable

## Decisión: `db_engine = "postgres"` (default)

Por recomendación de `docs/experimento_asr.md §6.4.11 opción B`, el default es
**OCI Database with PostgreSQL** (servicio gestionado de PostgreSQL de OCI).

### Por qué postgres es el default

1. **Drop-in con el experimento local**: el experimento en kind usa PostgreSQL 16 +
   CloudNativePG. OCI Database with PostgreSQL usa el mismo wire protocol, el mismo
   driver JDBC (`org.postgresql:postgresql`), y el mismo dialecto SQL. El código de
   aplicación no cambia al migrar de kind a OKE.

2. **Reducción de riesgo**: no se introduce un cambio de motor (Oracle vs PostgreSQL)
   en la misma operación que el despliegue a OKE.

3. **Iterabilidad**: permite validar ASR-1/ASR-2 en OKE con el mismo binario que en
   kind, eliminando una fuente de variabilidad.

### Cuándo usar `db_engine = "atp"`

Solo si el equipo de Cumplimiento del banco requiere específicamente **Autonomous
Database ATP** por razones regulatorias (ATP tiene certificaciones adicionales que
pueden ser mandatorias en ciertos jurisdicciones).

**Advertencia**: `atp` usa **Oracle Database**, NO PostgreSQL. Esto implica:
- Migración de driver: `org.postgresql:postgresql` → `com.oracle.database.jdbc:ojdbc11`
- Cambio de dialecto Hibernate: `PostgreSQLDialect` → `OracleDialect`
- Adaptar secuencias (`SERIAL`/`BIGSERIAL` → `SEQUENCE`)
- Adaptar tipos de dato (ej: `TEXT` → `CLOB` en Oracle)

Ver la tabla completa de trade-offs en `docs/experimento_asr.md §6.4.11 Matiz 3`.

## Uso

```hcl
module "db_pe" {
  source         = "./db"
  compartment_ocid = var.compartment_ocid
  db_engine      = "postgres"   # o "atp" si Cumplimiento lo exige
  pais           = "pe"
  db_subnet_id   = module.networking.db_subnet_id
  db_password    = var.db_password
}
```

## Outputs

| Output | Descripción |
|--------|-------------|
| `db_connection_string` | JDBC connection string listo para usar en la app |
| `db_engine_used` | Motor efectivamente aprovisionado |
| `db_system_id` | OCID del recurso de base de datos |

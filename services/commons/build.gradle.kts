// commons — módulo compartido: entidades de dominio, eventos, configuración de métricas
// NO es un servicio Spring Boot; no tiene Jib ni spring-boot plugin
plugins {
    java
}

dependencies {
    // Micrometer Core (para HistogramBucketsConfig y MeterFilter)
    implementation("io.micrometer:micrometer-core:1.13.6")

    // Jackson para serialización de eventos en el outbox
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.2")
    implementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.17.2")

    // Spring JDBC annotations (solo para @Transactional en la interfaz de repositorio)
    implementation("org.springframework:spring-tx:6.1.14")

    // Logging
    implementation("org.slf4j:slf4j-api:2.0.16")

    // Tests
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.3")
    testImplementation("org.assertj:assertj-core:3.26.3")
}

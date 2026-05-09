// outbox-dispatcher — implementación del patrón Outbox Pattern.
// NOTA ARQUITECTÓNICA: NO es un componente del modelo (componentes.jpeg).
// Es un detalle de implementación — documenta en commit F4.
// Lee cdt.outbox_cdt_eventos y publica a cdt.eventos en Redpanda.
plugins {
    id("org.springframework.boot")
    id("io.spring.dependency-management")
    id("com.google.cloud.tools.jib")
    java
}

dependencies {
    // Spring Boot Web (para /actuator/prometheus y health)
    implementation("org.springframework.boot:spring-boot-starter-web")

    // Spring Data JDBC (para el polling de la tabla outbox)
    implementation("org.springframework.boot:spring-boot-starter-data-jdbc")

    // PostgreSQL driver
    runtimeOnly("org.postgresql:postgresql")

    // Spring Kafka 3.2.x (client 3.7 via BOM de Spring Boot 3.3.5)
    implementation("org.springframework.kafka:spring-kafka")

    // Actuator + Prometheus
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    // Jackson
    implementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310")

    // Lombok
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")

    // Tests
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.kafka:spring-kafka-test")
    testImplementation("com.h2database:h2")
}

jib {
    from {
        image = "eclipse-temurin:21-jre-jammy"
    }
    to {
        val registry = System.getenv("REGISTRY") ?: "kind-registry:5000"
        image = "$registry/linea-verde/outbox-dispatcher"
        tags = setOf("latest", project.version.toString())
    }
    container {
        jvmFlags = listOf(
            "-XX:+UseG1GC",
            "-XX:MaxRAMPercentage=75.0"
        )
        ports = listOf("8080")
        user = "1000:1000"
        labels.put("app.kubernetes.io/component", "OutboxDispatcher")
        labels.put("app.kubernetes.io/part-of", "linea-verde-experimento")
    }
}

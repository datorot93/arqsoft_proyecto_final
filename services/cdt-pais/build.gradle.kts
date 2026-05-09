// cdt-pais — implementa CDTXPais (LineaVerde). Una sola imagen, 3 deployments por país.
// País parametrizado por env LV_PAIS=pe|mx|co. NO crear 3 imágenes distintas.
plugins {
    id("org.springframework.boot")
    id("io.spring.dependency-management")
    id("com.google.cloud.tools.jib")
    java
}

dependencies {
    // Spring Boot Web (servlet, virtual threads vía spring.threads.virtual.enabled=true)
    implementation("org.springframework.boot:spring-boot-starter-web")

    // Spring Data JDBC (HikariCP 5.x incluido transitivamente)
    implementation("org.springframework.boot:spring-boot-starter-data-jdbc")

    // PostgreSQL driver
    runtimeOnly("org.postgresql:postgresql")

    // Actuator + Prometheus (Micrometer 1.13.x via BOM de Spring Boot 3.3.5)
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    // AOP: requerido para que @Timed (Micrometer) funcione vía TimedAspect
    implementation("org.springframework.boot:spring-boot-starter-aop")

    // Validación Bean Validation
    implementation("org.springframework.boot:spring-boot-starter-validation")

    // Jackson (serialización payload outbox)
    implementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310")

    // Lombok (reducción de boilerplate)
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")

    // Tests
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("com.h2database:h2")
}

// Jib — una sola imagen multi-país, parametrizada por env LV_PAIS en runtime
jib {
    from {
        image = "eclipse-temurin:21-jre-jammy"
    }
    to {
        // Registry parametrizable: REGISTRY env var o kind-registry:5000 local
        val registry = System.getenv("REGISTRY") ?: "kind-registry:5000"
        image = "$registry/linea-verde/cdt-pais"
        // Una sola imagen; los tags pe/mx/co apuntan al mismo digest (T-12)
        tags = setOf("latest", project.version.toString())
    }
    container {
        jvmFlags = listOf(
            "-XX:+UseG1GC",
            "-XX:MaxRAMPercentage=75.0",
            "-Djdk.tracePinnedThreads=${System.getenv("TRACE_PINNED_THREADS") ?: "off"}"
        )
        ports = listOf("8080")
        user = "1000:1000"
        labels.put("app.kubernetes.io/component", "CDTXPais")
        labels.put("app.kubernetes.io/part-of", "linea-verde-experimento")
    }
}

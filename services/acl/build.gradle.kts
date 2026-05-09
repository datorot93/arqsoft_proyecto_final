// acl — implementa el subsistema Integracion (AdaptadorCore + CircuitBreaker).
// Único punto de salida autorizado hacia core-stub. NUNCA invocado directamente por cdt-pais.
plugins {
    id("org.springframework.boot")
    id("io.spring.dependency-management")
    id("com.google.cloud.tools.jib")
    java
}

dependencies {
    // Spring Boot Web (servlet + virtual threads)
    implementation("org.springframework.boot:spring-boot-starter-web")

    // Bean Validation
    implementation("org.springframework.boot:spring-boot-starter-validation")

    // Actuator + Prometheus
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    // Resilience4j — CB, Bulkhead, Retry con jitter
    // Versión 2.2.0 pinneada en versions.env
    implementation("io.github.resilience4j:resilience4j-spring-boot3:2.2.0")
    implementation("io.github.resilience4j:resilience4j-micrometer:2.2.0")

    // Apache HttpComponents 5 para pool HTTP acotado (RestClient usa esto)
    implementation("org.apache.httpcomponents.client5:httpclient5:5.3.1")

    // Spring AOP (requerido por Resilience4j annotations)
    implementation("org.springframework.boot:spring-boot-starter-aop")

    // Lombok
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")

    // Tests
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("io.github.resilience4j:resilience4j-spring-boot3:2.2.0")
}

jib {
    from {
        image = "eclipse-temurin:21-jre-jammy"
    }
    to {
        val registry = System.getenv("REGISTRY") ?: "kind-registry:5000"
        image = "$registry/linea-verde/acl"
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
        labels.put("app.kubernetes.io/component", "AdaptadorCore")
        labels.put("app.kubernetes.io/part-of", "linea-verde-experimento")
    }
}

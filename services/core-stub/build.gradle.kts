// core-stub — implementa el stub de CoreBancoZ para el experimento.
// Inyecta latencia Pareto Tipo II (xm=80, α=2.5) y errores Bernoulli.
// Apache Commons Math 3.6.x SOLO en este módulo.
// DESVIACIÓN DEL SPEC: el spec indica WebFlux pero el agente prohíbe WebFlux
// y exige coherencia con virtual threads. Se usa Spring Web servlet + virtual threads.
plugins {
    id("org.springframework.boot")
    id("io.spring.dependency-management")
    id("com.google.cloud.tools.jib")
    java
}

dependencies {
    // Spring Boot Web SERVLET (NO WebFlux — coherencia con virtual threads del agente)
    implementation("org.springframework.boot:spring-boot-starter-web")

    // Apache Commons Math 3.6.x — distribuciones Pareto y Bernoulli
    // SOLO en core-stub según el spec
    implementation("org.apache.commons:commons-math3:3.6.1")

    // Actuator + Prometheus
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    runtimeOnly("io.micrometer:micrometer-registry-prometheus")

    // Lombok
    compileOnly("org.projectlombok:lombok")
    annotationProcessor("org.projectlombok:lombok")

    // Tests
    testImplementation("org.springframework.boot:spring-boot-starter-test")
}

jib {
    from {
        image = "eclipse-temurin:21-jre-jammy"
    }
    to {
        val registry = System.getenv("REGISTRY") ?: "kind-registry:5000"
        image = "$registry/linea-verde/core-stub"
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
        labels.put("app.kubernetes.io/component", "CoreBancoZStub")
        labels.put("app.kubernetes.io/part-of", "linea-verde-experimento")
    }
}

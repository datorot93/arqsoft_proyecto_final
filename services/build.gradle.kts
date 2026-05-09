// build.gradle.kts raíz — Banco Z Línea Verde F4
// Aplica plugins comunes a todos los subproyectos de servicio (no a commons)
plugins {
    id("org.springframework.boot")       version "3.3.5" apply false
    id("io.spring.dependency-management") version "1.1.6" apply false
    id("com.google.cloud.tools.jib")     version "3.4.4" apply false
}

// Configuración compartida para todos los subproyectos
subprojects {
    apply(plugin = "java")

    group = "co.bancoz.lineaverde"
    version = "0.1.0-SNAPSHOT"

    // Java 21 LTS — requisito del stack pinneado
    configure<JavaPluginExtension> {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(21))
        }
    }

    tasks.withType<JavaCompile> {
        options.encoding = "UTF-8"
        // --enable-preview no es requerido por Spring Boot 3.3; se omite para evitar
        // problemas con Jib que no soporta fácilmente preview en tiempo de ejecución.
        // Si se requiere alguna preview feature específica, agregar aquí.
    }

    tasks.withType<Test> {
        useJUnitPlatform()
        jvmArgs("-Djdk.virtualThreadScheduler.parallelism=2")
    }
}

// Configuración específica para los subproyectos que son servicios Spring Boot
configure(subprojects.filter { it.name != "commons" }) {
    apply(plugin = "org.springframework.boot")
    apply(plugin = "io.spring.dependency-management")
    apply(plugin = "com.google.cloud.tools.jib")

    // Dependencia común: commons
    dependencies {
        "implementation"(project(":commons"))
    }
}

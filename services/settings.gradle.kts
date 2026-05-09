// Banco Z – Línea Verde: mono-repo Gradle multi-proyecto (F4 – Servicios de aplicación)
// Versiones pinneadas en versions.env: Spring Boot 3.3.5, Java 21, Jib 3.4.4, Gradle 8.10
rootProject.name = "linea-verde-services"

include(
    "commons",
    "cdt-pais",
    "acl",
    "outbox-dispatcher",
    "core-stub"
)

// Repositorios del Plugin Management (deben declararse aquí, antes de los subproyectos)
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

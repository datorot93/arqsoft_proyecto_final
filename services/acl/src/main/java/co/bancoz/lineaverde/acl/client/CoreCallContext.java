package co.bancoz.lineaverde.acl.client;

/**
 * ThreadLocal con metadatos del request actual del ACL hacia el core.
 * Permite que CoreClient lea el header X-Stub-Error-Rate recibido por el AclController
 * y lo reenvíe al core-stub para los tests del gate F4 (T-7, T-8).
 *
 * NOTA: Compatible con virtual threads — Java 21 asigna un ThreadLocal nuevo por cada
 * virtual thread, así que no hay leakage entre requests concurrentes.
 */
public final class CoreCallContext {

    private static final ThreadLocal<String> ERROR_RATE = new ThreadLocal<>();

    private CoreCallContext() {}

    public static void setErrorRate(String rate) {
        ERROR_RATE.set(rate);
    }

    public static String getErrorRate() {
        return ERROR_RATE.get();
    }

    public static void clear() {
        ERROR_RATE.remove();
    }
}

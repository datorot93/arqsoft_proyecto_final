package co.bancoz.lineaverde.acl.config;

import org.apache.hc.client5.http.impl.classic.CloseableHttpClient;
import org.apache.hc.client5.http.impl.classic.HttpClients;
import org.apache.hc.client5.http.impl.io.PoolingHttpClientConnectionManager;
import org.apache.hc.core5.pool.PoolConcurrencyPolicy;
import org.apache.hc.core5.pool.PoolReusePolicy;
import org.apache.hc.core5.util.TimeValue;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.HttpComponentsClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

/**
 * Configuración del pool HTTP hacia el core-stub.
 * Usa Apache HttpComponents 5 con PoolingHttpClientConnectionManager para
 * acotar el número de conexiones simultáneas (análogo a HikariCP para DB).
 *
 * maxTotal = 20: equivalente al Bulkhead.maxConcurrentCalls. Así el pool
 * nunca excede lo que el Bulkhead permite.
 */
@Configuration
public class HttpClientConfig {

    @Bean
    public RestClient restClient() {
        // HttpComponents 5 API: TTL se configura en el constructor del PoolingConnectionManager
        PoolingHttpClientConnectionManager connectionManager =
                new PoolingHttpClientConnectionManager(
                        null,                          // socketFactoryRegistry (default)
                        PoolConcurrencyPolicy.STRICT,
                        PoolReusePolicy.LIFO,
                        TimeValue.ofSeconds(60)        // TTL de conexión
                );
        // Máximo de conexiones totales (todas las rutas)
        connectionManager.setMaxTotal(20);
        // Máximo por ruta (solo hay una ruta: core-stub)
        connectionManager.setDefaultMaxPerRoute(20);

        CloseableHttpClient httpClient = HttpClients.custom()
                .setConnectionManager(connectionManager)
                .evictExpiredConnections()
                .evictIdleConnections(TimeValue.ofSeconds(30))
                .build();

        HttpComponentsClientHttpRequestFactory factory = new HttpComponentsClientHttpRequestFactory(httpClient);
        factory.setConnectTimeout(2000);  // 2s connection timeout
        factory.setConnectionRequestTimeout(2000);

        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}

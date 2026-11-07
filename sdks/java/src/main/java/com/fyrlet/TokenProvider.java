package com.fyrlet;

/**
 * Supplies a short-lived Fyrlet user session token ({@code rts_...}).
 *
 * <p>When {@code forceRefresh} is {@code true}, revalidate the host login and obtain a new session. To
 * stop recovery after the host login has ended, throw an {@link ApiException} with code
 * {@code UNAUTHENTICATED}. Any other exception is reported as a retryable network failure.</p>
 */
@FunctionalInterface
public interface TokenProvider {

    /**
     * Returns a user session token beginning with {@code rts_}.
     *
     * @param forceRefresh whether the caller needs a newly issued session
     * @return the user session token
     * @throws Exception when the host login cannot be verified or a session cannot be obtained
     */
    String getToken(boolean forceRefresh) throws Exception;
}

#include "elis_tls.h"
#include <stdlib.h>

// empty off glibc: the static musl build leaves the relay out and has no system OpenSSL
#if defined(__GLIBC__)
#include <limits.h>
#include <openssl/err.h>
#include <openssl/ssl.h>

elis_tls_context *elis_tls_server_context(const char *cert_path, const char *key_path) {
    SSL_CTX *context = SSL_CTX_new(TLS_server_method());
    if (context == NULL) return NULL;
    if (SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) != 1
        || SSL_CTX_use_certificate_chain_file(context, cert_path) != 1
        || SSL_CTX_use_PrivateKey_file(context, key_path, SSL_FILETYPE_PEM) != 1
        || SSL_CTX_check_private_key(context) != 1) {
        SSL_CTX_free(context);
        ERR_clear_error();
        return NULL;
    }
    return (elis_tls_context *)context;
}

elis_tls_context *elis_tls_client_context(void) {
    SSL_CTX *context = SSL_CTX_new(TLS_client_method());
    if (context != NULL) SSL_CTX_set_verify(context, SSL_VERIFY_NONE, NULL);
    return (elis_tls_context *)context;
}

void elis_tls_context_free(elis_tls_context *context) { SSL_CTX_free((SSL_CTX *)context); }

elis_tls *elis_tls_new(elis_tls_context *context, int fd, int server) {
    SSL *ssl = SSL_new((SSL_CTX *)context);
    if (ssl == NULL) return NULL;
    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return NULL;
    }
    if (server) SSL_set_accept_state(ssl); else SSL_set_connect_state(ssl);
    // a retried write may come from a moved Swift buffer
    SSL_set_mode(ssl, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
    return (elis_tls *)ssl;
}

void elis_tls_free(elis_tls *tls) { SSL_free((SSL *)tls); }

// the error queue is per thread and a dispatch queue moves between threads, so every call starts it empty
static long outcome(SSL *ssl, int result, long closed) {
    int error = SSL_get_error(ssl, result);
    ERR_clear_error();
    switch (error) {
    case SSL_ERROR_WANT_READ: return ELIS_TLS_WANT_READ;
    case SSL_ERROR_WANT_WRITE: return ELIS_TLS_WANT_WRITE;
    case SSL_ERROR_ZERO_RETURN: return closed;
    default: return ELIS_TLS_FAILED;
    }
}

int elis_tls_handshake(elis_tls *tls) {
    ERR_clear_error();
    int result = SSL_do_handshake((SSL *)tls);
    return result == 1 ? 1 : (int)outcome((SSL *)tls, result, ELIS_TLS_FAILED);
}

long elis_tls_read(elis_tls *tls, void *buffer, size_t count) {
    ERR_clear_error();
    int result = SSL_read((SSL *)tls, buffer, count > INT_MAX ? INT_MAX : (int)count);
    return result > 0 ? result : outcome((SSL *)tls, result, 0);
}

long elis_tls_write(elis_tls *tls, const void *bytes, size_t count) {
    ERR_clear_error();
    int result = SSL_write((SSL *)tls, bytes, count > INT_MAX ? INT_MAX : (int)count);
    return result > 0 ? result : outcome((SSL *)tls, result, ELIS_TLS_FAILED);
}

void elis_tls_shutdown(elis_tls *tls) {
    ERR_clear_error();
    SSL_shutdown((SSL *)tls);
    ERR_clear_error();
}

long elis_tls_peer_certificate(elis_tls *tls, unsigned char *out, size_t capacity) {
    X509 *cert = SSL_get1_peer_certificate((SSL *)tls);
    if (cert == NULL) return -1;
    int length = i2d_X509(cert, NULL);
    if (length > 0 && (size_t)length <= capacity) i2d_X509(cert, &out);
    X509_free(cert);
    return length;
}
#endif

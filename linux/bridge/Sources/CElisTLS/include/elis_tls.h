#pragma once
#include <stddef.h>

// The OpenSSL calls the Linux phone relay makes. The handles are opaque, so Swift imports none of OpenSSL.
typedef struct elis_tls_context elis_tls_context;
typedef struct elis_tls elis_tls;

#define ELIS_TLS_WANT_READ (-1)
#define ELIS_TLS_WANT_WRITE (-2)
#define ELIS_TLS_FAILED (-3)

/// A TLS 1.2+ server context for the PEM certificate and key; NULL when they do not load or do not match.
elis_tls_context *elis_tls_server_context(const char *cert_path, const char *key_path);
/// A client context that trusts any certificate, for a caller that pins the fingerprint itself.
elis_tls_context *elis_tls_client_context(void);
void elis_tls_context_free(elis_tls_context *context);

/// The server or client end on the non-blocking socket `fd`, which stays the caller's to close.
elis_tls *elis_tls_new(elis_tls_context *context, int fd, int server);
void elis_tls_free(elis_tls *tls);

/// 1 once the handshake is done, else a code above.
int elis_tls_handshake(elis_tls *tls);
/// The bytes read, 0 at the peer's close_notify, or a code above.
long elis_tls_read(elis_tls *tls, void *buffer, size_t count);
/// The bytes written, possibly fewer than `count`, or a code above.
long elis_tls_write(elis_tls *tls, const void *bytes, size_t count);
/// Sends close_notify without waiting for the peer's.
void elis_tls_shutdown(elis_tls *tls);
/// The peer certificate's DER length, copied into `out` when it fits; -1 without one.
long elis_tls_peer_certificate(elis_tls *tls, unsigned char *out, size_t capacity);

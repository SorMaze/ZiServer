#include <stdint.h>
#include <string.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/crypto.h>

#if defined(_MSC_VER)
#define ZISERVER_THREAD_LOCAL __declspec(thread)
#else
#define ZISERVER_THREAD_LOCAL _Thread_local
#endif

static BIO_METHOD *ziserver_socket_bio_method = NULL;
static CRYPTO_ONCE ziserver_socket_bio_once = CRYPTO_ONCE_STATIC_INIT;
static ZISERVER_THREAD_LOCAL int ziserver_last_ssl_error = 0;
static ZISERVER_THREAD_LOCAL int ziserver_last_io_error = 0;
static ZISERVER_THREAD_LOCAL char ziserver_last_error_text[256];

typedef int (*ziserver_io_read_fn)(
    void *userdata,
    const void *vtable,
    uintptr_t socket_handle,
    unsigned char *buffer,
    int len,
    int64_t read_deadline_ns
);

typedef int (*ziserver_io_write_fn)(
    void *userdata,
    const void *vtable,
    uintptr_t socket_handle,
    const unsigned char *buffer,
    int len
);

typedef struct {
    void *userdata;
    const void *vtable;
    uintptr_t socket_handle;
    ziserver_io_read_fn read;
    ziserver_io_write_fn write;
    int64_t read_deadline_ns;
} ziserver_bio_state;

static void ziserver_openssl_reset_error(void) {
    ziserver_last_ssl_error = 0;
    ziserver_last_io_error = 0;
    ziserver_last_error_text[0] = '\0';
    ERR_clear_error();
}

static int ziserver_socket_bio_create(BIO *bio) {
    BIO_set_init(bio, 1);
    BIO_set_data(bio, NULL);
    BIO_set_shutdown(bio, 0);
    return 1;
}

static int ziserver_socket_bio_destroy(BIO *bio) {
    if (bio == NULL) {
        return 0;
    }
    ziserver_bio_state *state = (ziserver_bio_state *)BIO_get_data(bio);
    if (state != NULL) {
        OPENSSL_free(state);
    }
    BIO_set_data(bio, NULL);
    BIO_set_init(bio, 0);
    return 1;
}

static int ziserver_socket_bio_read(BIO *bio, char *buffer, int len) {
    if (buffer == NULL || len <= 0) {
        return 0;
    }
    ziserver_bio_state *state = (ziserver_bio_state *)BIO_get_data(bio);
    if (state == NULL || state->read == NULL) {
        return -1;
    }
    BIO_clear_retry_flags(bio);
    int result = state->read(
        state->userdata,
        state->vtable,
        state->socket_handle,
        (unsigned char *)buffer,
        len,
        state->read_deadline_ns
    );
    ziserver_last_io_error = result < 0 ? result : 0;
    if (result == -2) {
        BIO_set_retry_read(bio);
        return -1;
    }
    return result;
}

static int ziserver_socket_bio_write(BIO *bio, const char *buffer, int len) {
    if (buffer == NULL || len <= 0) {
        return 0;
    }
    ziserver_bio_state *state = (ziserver_bio_state *)BIO_get_data(bio);
    if (state == NULL || state->write == NULL) {
        return -1;
    }
    BIO_clear_retry_flags(bio);
    int result = state->write(
        state->userdata,
        state->vtable,
        state->socket_handle,
        (const unsigned char *)buffer,
        len
    );
    ziserver_last_io_error = result < 0 ? result : 0;
    return result;
}

static long ziserver_socket_bio_ctrl(BIO *bio, int cmd, long num, void *ptr) {
    (void)bio;
    (void)num;
    (void)ptr;
    switch (cmd) {
        case BIO_CTRL_FLUSH:
            return 1;
        default:
            return 0;
    }
}

static void ziserver_init_socket_bio_method(void) {
    BIO_METHOD *method = BIO_meth_new(BIO_TYPE_SOURCE_SINK, "ziserver_socket");
    if (method == NULL) {
        return;
    }
    if (BIO_meth_set_write(method, ziserver_socket_bio_write) != 1 ||
        BIO_meth_set_read(method, ziserver_socket_bio_read) != 1 ||
        BIO_meth_set_ctrl(method, ziserver_socket_bio_ctrl) != 1 ||
        BIO_meth_set_create(method, ziserver_socket_bio_create) != 1 ||
        BIO_meth_set_destroy(method, ziserver_socket_bio_destroy) != 1) {
        BIO_meth_free(method);
        return;
    }
    ziserver_socket_bio_method = method;
}

static BIO_METHOD *ziserver_get_socket_bio_method(void) {
    if (!CRYPTO_THREAD_run_once(&ziserver_socket_bio_once, ziserver_init_socket_bio_method)) {
        return NULL;
    }
    return ziserver_socket_bio_method;
}

static BIO *ziserver_socket_bio_new(
    void *userdata,
    const void *vtable,
    uintptr_t socket_handle,
    int64_t read_deadline_ns,
    ziserver_io_read_fn read_fn,
    ziserver_io_write_fn write_fn
) {
    BIO_METHOD *method = ziserver_get_socket_bio_method();
    if (method == NULL) {
        return NULL;
    }
    BIO *bio = BIO_new(method);
    if (bio == NULL) {
        return NULL;
    }
    ziserver_bio_state *state = OPENSSL_zalloc(sizeof(*state));
    if (state == NULL) {
        BIO_free(bio);
        return NULL;
    }
    state->userdata = userdata;
    state->vtable = vtable;
    state->socket_handle = socket_handle;
    state->read = read_fn;
    state->write = write_fn;
    state->read_deadline_ns = read_deadline_ns;
    BIO_set_data(bio, state);
    BIO_set_init(bio, 1);
    return bio;
}

static int ziserver_openssl_select_alpn(
    SSL *ssl,
    const unsigned char **out,
    unsigned char *outlen,
    const unsigned char *in,
    unsigned int inlen,
    void *arg
) {
    static const unsigned char h3[] = {
        2, 'h', '3'
    };
    static const unsigned char http11[] = {
        8, 'h', 't', 't', 'p', '/', '1', '.', '1'
    };
    static const unsigned char h2_http11[] = {
        2, 'h', '2',
        8, 'h', 't', 't', 'p', '/', '1', '.', '1'
    };
    const int is_quic = SSL_is_quic(ssl);
    const unsigned char *protocols = is_quic ? h3 : (arg == NULL ? http11 : h2_http11);
    unsigned int protocols_len = is_quic ? sizeof(h3) : (arg == NULL ? sizeof(http11) : sizeof(h2_http11));

    if (SSL_select_next_proto((unsigned char **)out, outlen, protocols, protocols_len, in, inlen) == OPENSSL_NPN_NEGOTIATED) {
        return SSL_TLSEXT_ERR_OK;
    }
    return is_quic ? SSL_TLSEXT_ERR_ALERT_FATAL : SSL_TLSEXT_ERR_NOACK;
}

unsigned long ziserver_openssl_version_number(void) {
    return OpenSSL_version_num();
}

const char *ziserver_openssl_version_text(void) {
    return OpenSSL_version(OPENSSL_VERSION);
}

SSL_CTX *ziserver_openssl_server_ctx_new(
    const char *cert_file,
    const char *key_file,
    int min_tls_version,
    int advertise_h2
) {
    ziserver_openssl_reset_error();
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (ctx == NULL) {
        return NULL;
    }

    int openssl_min_version = min_tls_version >= 13 ? TLS1_3_VERSION : TLS1_2_VERSION;
    if (SSL_CTX_set_min_proto_version(ctx, openssl_min_version) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    if (SSL_CTX_set_ciphersuites(
            ctx,
            "TLS_AES_128_GCM_SHA256:"
            "TLS_CHACHA20_POLY1305_SHA256:"
            "TLS_AES_256_GCM_SHA384"
        ) != 1 ||
        SSL_CTX_set_cipher_list(
            ctx,
            "ECDHE-ECDSA-AES128-GCM-SHA256:"
            "ECDHE-RSA-AES128-GCM-SHA256:"
            "ECDHE-ECDSA-CHACHA20-POLY1305:"
            "ECDHE-RSA-CHACHA20-POLY1305:"
            "ECDHE-ECDSA-AES256-GCM-SHA384:"
            "ECDHE-RSA-AES256-GCM-SHA384"
        ) != 1 ||
        SSL_CTX_set1_groups_list(ctx, "X25519:P-256:P-384") != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    SSL_CTX_set_options(
        ctx,
        SSL_OP_NO_COMPRESSION | SSL_OP_CIPHER_SERVER_PREFERENCE
    );
#ifdef SSL_OP_NO_RENEGOTIATION
    SSL_CTX_set_options(ctx, SSL_OP_NO_RENEGOTIATION);
#endif
    SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS);

    static const unsigned char session_id_context[] = "ZiServer TLS";
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_SERVER);
    SSL_CTX_set_timeout(ctx, 300);
    if (SSL_CTX_set_session_id_context(
            ctx,
            session_id_context,
            sizeof(session_id_context) - 1
        ) != 1 ||
        SSL_CTX_set_num_tickets(ctx, 2) != 1 ||
        SSL_CTX_set_max_early_data(ctx, 0) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    SSL_CTX_set_alpn_select_cb(
        ctx,
        ziserver_openssl_select_alpn,
        advertise_h2 ? (void *)(uintptr_t)1 : NULL
    );

    if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    if (SSL_CTX_check_private_key(ctx) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    ziserver_openssl_reset_error();
    return ctx;
}

void ziserver_openssl_server_ctx_free(SSL_CTX *ctx) {
    if (ctx != NULL) {
        SSL_CTX_free(ctx);
    }
}

SSL_CTX *ziserver_openssl_client_ctx_new(int verify_peer) {
    ziserver_openssl_reset_error();
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (ctx == NULL) {
        return NULL;
    }
    if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1 ||
        SSL_CTX_set_ciphersuites(
            ctx,
            "TLS_AES_128_GCM_SHA256:"
            "TLS_CHACHA20_POLY1305_SHA256:"
            "TLS_AES_256_GCM_SHA384"
        ) != 1 ||
        SSL_CTX_set1_groups_list(ctx, "X25519:P-256:P-384") != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION);
    SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS);
    if (verify_peer) {
        if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
            SSL_CTX_free(ctx);
            return NULL;
        }
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    } else {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    }
    ziserver_openssl_reset_error();
    return ctx;
}

void ziserver_openssl_client_ctx_free(SSL_CTX *ctx) {
    if (ctx != NULL) {
        SSL_CTX_free(ctx);
    }
}

unsigned long ziserver_openssl_last_error(void) {
    return ERR_peek_last_error();
}

int ziserver_openssl_last_ssl_error(void) {
    return ziserver_last_ssl_error;
}

int ziserver_openssl_last_io_error(void) {
    return ziserver_last_io_error;
}

const char *ziserver_openssl_last_error_text(void) {
    unsigned long error_code = ERR_peek_last_error();
    if (error_code == 0) {
        ziserver_last_error_text[0] = '\0';
        return ziserver_last_error_text;
    }
    ERR_error_string_n(error_code, ziserver_last_error_text, sizeof(ziserver_last_error_text));
    return ziserver_last_error_text;
}

SSL *ziserver_openssl_server_conn_new(
    SSL_CTX *ctx,
    void *userdata,
    const void *vtable,
    uintptr_t socket_handle,
    int64_t read_deadline_ns,
    ziserver_io_read_fn read_fn,
    ziserver_io_write_fn write_fn
) {
    ziserver_openssl_reset_error();
    SSL *ssl = SSL_new(ctx);
    if (ssl == NULL) {
        return NULL;
    }

    BIO *bio = ziserver_socket_bio_new(
        userdata,
        vtable,
        socket_handle,
        read_deadline_ns,
        read_fn,
        write_fn
    );
    if (bio == NULL) {
        SSL_free(ssl);
        return NULL;
    }
    SSL_set_bio(ssl, bio, bio);

    int accept_result = SSL_accept(ssl);
    if (accept_result != 1) {
        ziserver_last_ssl_error = SSL_get_error(ssl, accept_result);
        SSL_free(ssl);
        return NULL;
    }

    ziserver_openssl_reset_error();
    return ssl;
}

SSL *ziserver_openssl_client_conn_new(
    SSL_CTX *ctx,
    void *userdata,
    const void *vtable,
    uintptr_t socket_handle,
    int64_t read_deadline_ns,
    ziserver_io_read_fn read_fn,
    ziserver_io_write_fn write_fn,
    const char *server_name,
    int advertise_h2
) {
    ziserver_openssl_reset_error();
    SSL *ssl = SSL_new(ctx);
    if (ssl == NULL) {
        return NULL;
    }
    if (server_name == NULL || server_name[0] == '\0' ||
        SSL_set_tlsext_host_name(ssl, server_name) != 1) {
        SSL_free(ssl);
        return NULL;
    }
    if (SSL_CTX_get_verify_mode(ctx) == SSL_VERIFY_PEER) {
        X509_VERIFY_PARAM *verify_params = SSL_get0_param(ssl);
        if (verify_params == NULL ||
            (X509_VERIFY_PARAM_set1_ip_asc(verify_params, server_name) != 1 &&
             SSL_set1_host(ssl, server_name) != 1)) {
            SSL_free(ssl);
            return NULL;
        }
    }

    static const unsigned char http11[] = {
        8, 'h', 't', 't', 'p', '/', '1', '.', '1'
    };
    static const unsigned char h2_http11[] = {
        2, 'h', '2',
        8, 'h', 't', 't', 'p', '/', '1', '.', '1'
    };
    const unsigned char *protocols = advertise_h2 ? h2_http11 : http11;
    unsigned int protocols_len = advertise_h2 ? sizeof(h2_http11) : sizeof(http11);
    if (SSL_set_alpn_protos(ssl, protocols, protocols_len) != 0) {
        SSL_free(ssl);
        return NULL;
    }

    BIO *bio = ziserver_socket_bio_new(
        userdata,
        vtable,
        socket_handle,
        read_deadline_ns,
        read_fn,
        write_fn
    );
    if (bio == NULL) {
        SSL_free(ssl);
        return NULL;
    }
    SSL_set_bio(ssl, bio, bio);

    int connect_result = SSL_connect(ssl);
    if (connect_result != 1) {
        ziserver_last_ssl_error = SSL_get_error(ssl, connect_result);
        SSL_free(ssl);
        return NULL;
    }
    ziserver_openssl_reset_error();
    return ssl;
}

void ziserver_openssl_conn_set_read_deadline(SSL *ssl, int64_t deadline_ns) {
    if (ssl == NULL) {
        return;
    }
    BIO *bio = SSL_get_rbio(ssl);
    ziserver_bio_state *state = bio == NULL ? NULL : (ziserver_bio_state *)BIO_get_data(bio);
    if (state != NULL) {
        state->read_deadline_ns = deadline_ns;
    }
}

void ziserver_openssl_server_conn_free(SSL *ssl) {
    if (ssl != NULL) {
        SSL_shutdown(ssl);
        SSL_free(ssl);
    }
}

int ziserver_openssl_conn_read(SSL *ssl, unsigned char *buffer, int len) {
    ziserver_openssl_reset_error();
    int result = SSL_read(ssl, buffer, len);
    if (result > 0) {
        return result;
    }
    ziserver_last_ssl_error = SSL_get_error(ssl, result);
    if (ziserver_last_ssl_error == SSL_ERROR_ZERO_RETURN ||
        (ziserver_last_ssl_error == SSL_ERROR_SYSCALL &&
         ziserver_last_io_error == 0 &&
         ERR_peek_last_error() == 0)) {
        return 0;
    }
    return -1;
}

int ziserver_openssl_conn_pending(SSL *ssl) {
    return ssl == NULL ? 0 : SSL_pending(ssl);
}

int ziserver_openssl_conn_write(SSL *ssl, const unsigned char *buffer, int len) {
    ziserver_openssl_reset_error();
    int result = SSL_write(ssl, buffer, len);
    if (result > 0) {
        return result;
    }
    ziserver_last_ssl_error = SSL_get_error(ssl, result);
    return -1;
}

int ziserver_openssl_conn_alpn(SSL *ssl) {
    const unsigned char *protocol = NULL;
    unsigned int protocol_len = 0;
    SSL_get0_alpn_selected(ssl, &protocol, &protocol_len);
    if (protocol_len == 8 && memcmp(protocol, "http/1.1", 8) == 0) {
        return 1;
    }
    if (protocol_len == 2 && memcmp(protocol, "h2", 2) == 0) {
        return 2;
    }
    return protocol_len == 0 ? 0 : 3;
}

const char *ziserver_openssl_conn_version(SSL *ssl) {
    return ssl == NULL ? "-" : SSL_get_version(ssl);
}

const char *ziserver_openssl_conn_cipher(SSL *ssl) {
    if (ssl == NULL) {
        return "-";
    }
    const SSL_CIPHER *cipher = SSL_get_current_cipher(ssl);
    return cipher == NULL ? "-" : SSL_CIPHER_get_name(cipher);
}

int ziserver_openssl_conn_session_reused(SSL *ssl) {
    return ssl == NULL ? 0 : SSL_session_reused(ssl);
}

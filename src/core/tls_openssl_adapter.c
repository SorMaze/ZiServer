#include <stdint.h>
#include <string.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/ocsp.h>
#include <openssl/pem.h>

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
    int len,
    int64_t write_deadline_ns
);

typedef struct {
    void *userdata;
    const void *vtable;
    uintptr_t socket_handle;
    ziserver_io_read_fn read;
    ziserver_io_write_fn write;
    int64_t read_deadline_ns;
    int64_t write_deadline_ns;
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
        len,
        state->write_deadline_ns
    );
    ziserver_last_io_error = result < 0 ? result : 0;
    // The BIO interface reports fatal I/O as -1; the typed reason remains in
    // ziserver_last_io_error so the Zig wrapper can classify the failure.
    return result < 0 ? -1 : result;
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
    int64_t write_deadline_ns,
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
    state->write_deadline_ns = write_deadline_ns;
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
#if OPENSSL_VERSION_NUMBER >= 0x30200000L
    const int is_quic = SSL_is_quic(ssl);
#else
    (void)ssl;
    const int is_quic = 0;
#endif
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

    X509 *certificate = SSL_CTX_get0_certificate(ctx);
    if (certificate == NULL || X509_cmp_current_time(X509_get0_notBefore(certificate)) >= 0 ||
        X509_cmp_current_time(X509_get0_notAfter(certificate)) <= 0) {
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

int ziserver_openssl_server_ctx_retain(SSL_CTX *ctx) {
    return SSL_CTX_up_ref(ctx);
}

static int ziserver_openssl_certificate_denied(
    X509 *certificate,
    const uint8_t *cert_hashes, size_t cert_count,
    const uint8_t *spki_hashes, size_t spki_count
) {
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    if (certificate == NULL) return -1;
    if (cert_count != 0) {
        if (X509_digest(certificate, EVP_sha256(), digest, &length) != 1 || length != 32) return -1;
        for (size_t i = 0; i < cert_count; ++i) {
            if (CRYPTO_memcmp(digest, cert_hashes + i * 32, 32) == 0) return 1;
        }
    }
    if (spki_count != 0) {
        // Hash the complete DER SubjectPublicKeyInfo, including its algorithm
        // identifier. X509_pubkey_digest hashes only the public-key BIT STRING.
        unsigned char *encoded = NULL;
        int size = i2d_X509_PUBKEY(X509_get_X509_PUBKEY(certificate), &encoded);
        if (size <= 0) return -1;
        int result = EVP_Digest(encoded, (size_t)size, digest, &length, EVP_sha256(), NULL);
        OPENSSL_free(encoded);
        if (result != 1 || length != 32) return -1;
        for (size_t i = 0; i < spki_count; ++i) {
            if (CRYPTO_memcmp(digest, spki_hashes + i * 32, 32) == 0) return 1;
        }
    }
    return 0;
}

int ziserver_openssl_server_ctx_denied(
    SSL_CTX *ctx,
    const uint8_t *cert_hashes, size_t cert_count,
    const uint8_t *spki_hashes, size_t spki_count
) {
    int result = ziserver_openssl_certificate_denied(
        SSL_CTX_get0_certificate(ctx), cert_hashes, cert_count, spki_hashes, spki_count);
    if (result != 0) return result;
    STACK_OF(X509) *chain = NULL;
    if (SSL_CTX_get0_chain_certs(ctx, &chain) != 1) return -1;
    for (int i = 0; chain != NULL && i < sk_X509_num(chain); ++i) {
        result = ziserver_openssl_certificate_denied(
            sk_X509_value(chain, i), cert_hashes, cert_count, spki_hashes, spki_count);
        if (result != 0) return result;
    }
    return 0;
}

typedef struct {
    uint8_t cert_hashes[64][32];
    size_t cert_count;
    uint8_t spki_hashes[64][32];
    size_t spki_count;
    OCSP_BASICRESP **responses;
    size_t response_count;
} ziserver_client_policy;

static CRYPTO_ONCE ziserver_client_policy_once = CRYPTO_ONCE_STATIC_INIT;
static int ziserver_client_policy_index = -1;

static void ziserver_client_policy_free(
    void *parent, void *pointer, CRYPTO_EX_DATA *data, int index, long argument, void *argument_pointer
) {
    (void)parent; (void)data; (void)index; (void)argument; (void)argument_pointer;
    ziserver_client_policy *policy = pointer;
    if (policy == NULL) return;
    for (size_t i = 0; i < policy->response_count; ++i) OCSP_BASICRESP_free(policy->responses[i]);
    OPENSSL_free(policy->responses);
    OPENSSL_free(policy);
}

static void ziserver_client_policy_index_init(void) {
    ziserver_client_policy_index = SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, ziserver_client_policy_free);
}

static int ziserver_ocsp_current(OCSP_SINGLERESP *single) {
    ASN1_GENERALIZEDTIME *revocation = NULL, *this_update = NULL, *next_update = NULL;
    int reason = 0;
    (void)OCSP_single_get0_status(single, &reason, &revocation, &this_update, &next_update);
    // Bound response age even if its issuer gives it a very distant expiry.
    return this_update != NULL && next_update != NULL &&
        OCSP_check_validity(this_update, next_update, 300, 86400) == 1;
}

static int ziserver_client_verify(int preverified, X509_STORE_CTX *verification) {
    if (!preverified) return 0;
    if (X509_STORE_CTX_get_error_depth(verification) != 0) return 1;
    SSL *ssl = X509_STORE_CTX_get_ex_data(verification, SSL_get_ex_data_X509_STORE_CTX_idx());
    if (ssl == NULL) return 0;
    SSL_CTX *context = SSL_get_SSL_CTX(ssl);
    ziserver_client_policy *policy = SSL_CTX_get_ex_data(context, ziserver_client_policy_index);
    STACK_OF(X509) *chain = X509_STORE_CTX_get0_chain(verification);
    if (policy == NULL || chain == NULL || sk_X509_num(chain) == 0) return 0;
    for (int i = 0; i < sk_X509_num(chain); ++i) {
        int denied = ziserver_openssl_certificate_denied(sk_X509_value(chain, i),
            &policy->cert_hashes[0][0], policy->cert_count,
            &policy->spki_hashes[0][0], policy->spki_count);
        if (denied != 0) {
            X509_STORE_CTX_set_error(verification, denied > 0 ? X509_V_ERR_CERT_REVOKED : X509_V_ERR_APPLICATION_VERIFICATION);
            return 0;
        }
    }
    if (policy->response_count == 0) return 1;
    X509 *leaf = sk_X509_value(chain, 0);
    X509 *issuer = sk_X509_value(chain, sk_X509_num(chain) > 1 ? 1 : 0);
    int found_good = 0;
    for (size_t i = 0; i < policy->response_count; ++i) {
        OCSP_BASICRESP *basic = policy->responses[i];
        if (OCSP_basic_verify(basic, chain, SSL_CTX_get_cert_store(context), OCSP_NOEXPLICIT) != 1) continue;
        for (int j = 0; j < OCSP_resp_count(basic); ++j) {
            OCSP_SINGLERESP *single = OCSP_resp_get0(basic, j);
            const OCSP_CERTID *response_id = OCSP_SINGLERESP_get0_id(single);
            ASN1_OBJECT *algorithm = NULL;
            if (OCSP_id_get0_info(NULL, &algorithm, NULL, NULL, (OCSP_CERTID *)response_id) != 1) continue;
            const EVP_MD *digest = EVP_get_digestbyobj(algorithm);
            if (digest == NULL) continue;
            OCSP_CERTID *expected = OCSP_cert_to_id(digest, leaf, issuer);
            if (expected == NULL) continue;
            int matches = OCSP_id_cmp(expected, response_id) == 0;
            OCSP_CERTID_free(expected);
            if (!matches) continue;
            int status = OCSP_single_get0_status(single, NULL, NULL, NULL, NULL);
            if (status == V_OCSP_CERTSTATUS_REVOKED) {
                X509_STORE_CTX_set_error(verification, X509_V_ERR_CERT_REVOKED);
                return 0;
            }
            if (status == V_OCSP_CERTSTATUS_GOOD && ziserver_ocsp_current(single)) found_good = 1;
        }
    }
    if (found_good) return 1;
    X509_STORE_CTX_set_error(verification, X509_V_ERR_APPLICATION_VERIFICATION);
    return 0;
}

static int ziserver_client_crls_valid(X509_STORE *store, const char *file) {
    BIO *input = BIO_new_file(file, "rb");
    if (input == NULL) return 0;
    STACK_OF(X509_INFO) *entries = PEM_X509_INFO_read_bio(input, NULL, NULL, NULL);
    BIO_free(input);
    if (entries == NULL) return 0;
    X509_STORE_CTX *verification = X509_STORE_CTX_new();
    int valid = 0, count = 0;
    if (verification == NULL || X509_STORE_CTX_init(verification, store, NULL, NULL) != 1) goto done;
    for (int i = 0; i < sk_X509_INFO_num(entries); ++i) {
        X509_CRL *crl = sk_X509_INFO_value(entries, i)->crl;
        if (crl == NULL) continue;
        if (++count > 64 || X509_CRL_get0_nextUpdate(crl) == NULL ||
            X509_cmp_current_time(X509_CRL_get0_lastUpdate(crl)) >= 0 ||
            X509_cmp_current_time(X509_CRL_get0_nextUpdate(crl)) <= 0) goto done;
        STACK_OF(X509) *issuers = X509_STORE_CTX_get1_certs(verification, X509_CRL_get_issuer(crl));
        int signature_valid = 0;
        for (int j = 0; issuers != NULL && j < sk_X509_num(issuers); ++j) {
            if (X509_CRL_verify(crl, X509_get0_pubkey(sk_X509_value(issuers, j))) == 1) signature_valid = 1;
        }
        sk_X509_pop_free(issuers, X509_free);
        if (!signature_valid) goto done;
    }
    valid = count != 0;
done:
    X509_STORE_CTX_free(verification);
    sk_X509_INFO_pop_free(entries, X509_INFO_free);
    return valid;
}

int ziserver_openssl_server_ctx_client_auth(
    SSL_CTX *context, const char *ca_file, const char *crl_file,
    const char *const *ocsp_files, size_t ocsp_count,
    const uint8_t *cert_hashes, size_t cert_count,
    const uint8_t *spki_hashes, size_t spki_count
) {
    if (cert_count > 64 || spki_count > 64 || ocsp_count > 64 ||
        CRYPTO_THREAD_run_once(&ziserver_client_policy_once, ziserver_client_policy_index_init) != 1 ||
        ziserver_client_policy_index < 0 ||
        SSL_CTX_load_verify_locations(context, ca_file, NULL) != 1) return 0;
    X509_STORE *store = SSL_CTX_get_cert_store(context);
    if (crl_file != NULL &&
        (!ziserver_client_crls_valid(store, crl_file) ||
         X509_STORE_load_file(store, crl_file) != 1 ||
         X509_STORE_set_flags(store, X509_V_FLAG_CRL_CHECK | X509_V_FLAG_CRL_CHECK_ALL) != 1)) return 0;
    ziserver_client_policy *policy = OPENSSL_zalloc(sizeof(*policy));
    if (policy == NULL) return 0;
    if (SSL_CTX_set_ex_data(context, ziserver_client_policy_index, policy) != 1) {
        OPENSSL_free(policy);
        return 0;
    }
    policy->cert_count = cert_count;
    policy->spki_count = spki_count;
    if (cert_count != 0) memcpy(policy->cert_hashes, cert_hashes, cert_count * 32);
    if (spki_count != 0) memcpy(policy->spki_hashes, spki_hashes, spki_count * 32);
    if (ocsp_count != 0) {
        policy->responses = OPENSSL_zalloc(ocsp_count * sizeof(*policy->responses));
        if (policy->responses == NULL) return 0;
    }
    for (size_t i = 0; i < ocsp_count; ++i) {
        BIO *input = BIO_new_file(ocsp_files[i], "rb");
        if (input == NULL) return 0;
        OCSP_RESPONSE *response = d2i_OCSP_RESPONSE_bio(input, NULL);
        BIO_free(input);
        if (response == NULL) return 0;
        if (OCSP_response_status(response) != OCSP_RESPONSE_STATUS_SUCCESSFUL) {
            OCSP_RESPONSE_free(response);
            return 0;
        }
        OCSP_BASICRESP *basic = OCSP_response_get1_basic(response);
        OCSP_RESPONSE_free(response);
        if (basic == NULL) return 0;
        policy->responses[policy->response_count++] = basic;
        if (OCSP_basic_verify(basic, NULL, store, OCSP_NOEXPLICIT) != 1) return 0;
        for (int j = 0; j < OCSP_resp_count(basic); ++j) {
            if (!ziserver_ocsp_current(OCSP_resp_get0(basic, j))) return 0;
        }
    }
    STACK_OF(X509_NAME) *names = SSL_load_client_CA_file(ca_file);
    if (names == NULL) return 0;
    SSL_CTX_set_client_CA_list(context, names);
    // A resumed session can skip certificate verification callbacks. Require
    // fresh CRL/OCSP checks on every mTLS handshake, including after expiry.
    SSL_CTX_set_session_cache_mode(context, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_options(context, SSL_OP_NO_TICKET);
    if (SSL_CTX_set_num_tickets(context, 0) != 1) return 0;
    SSL_CTX_set_verify(context, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, ziserver_client_verify);
    return 1;
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
    int64_t write_deadline_ns,
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
        write_deadline_ns,
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
    int64_t write_deadline_ns,
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
        write_deadline_ns,
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

void ziserver_openssl_conn_set_write_deadline(SSL *ssl, int64_t deadline_ns) {
    if (ssl == NULL) {
        return;
    }
    BIO *bio = SSL_get_wbio(ssl);
    ziserver_bio_state *state = bio == NULL ? NULL : (ziserver_bio_state *)BIO_get_data(bio);
    if (state != NULL) {
        state->write_deadline_ns = deadline_ns;
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

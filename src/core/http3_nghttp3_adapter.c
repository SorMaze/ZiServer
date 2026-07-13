// ZiServer HTTP/3 adapter — ngtcp2 (QUIC transport) + nghttp3 (HTTP/3 frames)
// Single-connection server: accepts one QUIC connection, handles HTTP/3 requests,
// dispatches to Zig handlers, writes responses, and returns a summary.

// Winsock must come before windows.h (pulled by OpenSSL on Windows)
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_ossl.h>
#include <nghttp3/nghttp3.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifndef _WIN32
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#endif

// ---------------------------------------------------------------------------
// Callback function types — match Zig extern signatures
// ---------------------------------------------------------------------------
typedef int (*ziserver_quic_read_fn)(void *userdata, uint8_t *buf, size_t buflen,
                                       void *addr_out, size_t *addrlen_out);
typedef int (*ziserver_quic_write_fn)(void *userdata, const uint8_t *data, size_t datalen,
                                       const void *addr, size_t addrlen);
typedef int (*ziserver_h3_dispatch_fn)(void *userdata, const void *request, void *capture);
typedef void (*ziserver_h3_release_fn)(void *userdata, void *capture);

// ---------------------------------------------------------------------------
// Types must match http2.zig's Request and Summary (layout-compatible)
// ---------------------------------------------------------------------------
typedef struct {
    const char *method_ptr;
    size_t method_len;
    const char *path_ptr;
    size_t path_len;
    const char *authority_ptr;
    size_t authority_len;
    const void *headers_ptr;
    size_t headers_len;
    const char *body_ptr;
    size_t body_len;
    uint16_t error_status;
} ziserver_h3_request;

typedef struct {
    uint64_t requests;
    uint32_t highest_stream_id;
    uint8_t goaway_sent;
} ziserver_quic_summary;

// ---------------------------------------------------------------------------
// Per-stream HTTP/3 request state
// ---------------------------------------------------------------------------
#define H3_MAX_HEADERS 64
#define H3_MAX_HEADER_BYTES 65536
#define SERVER_SCID_LEN 18

typedef struct {
    int64_t stream_id;
    char *method;
    size_t method_len;
    char *path;
    size_t path_len;
    char *authority;
    size_t authority_len;
    char *header_buf;
    size_t header_buf_len;
    size_t header_buf_cap;
    char *body;
    size_t body_len;
    size_t body_cap;
    int headers_complete;
    int dispatched;
} h3_stream_state;

// ---------------------------------------------------------------------------
// Main session state
// ---------------------------------------------------------------------------
typedef struct quic_session quic_session;
struct quic_session {
    void *userdata;
    ziserver_quic_read_fn read_fn;
    ziserver_quic_write_fn write_fn;
    ziserver_h3_dispatch_fn dispatch_fn;
    ziserver_h3_release_fn release_fn;

    size_t max_header_bytes;
    size_t max_body_bytes;
    size_t max_requests;
    size_t request_count;

    ngtcp2_conn *quic_conn;
    nghttp3_conn *http3_conn;
    SSL_CTX *ssl_ctx;

    ngtcp2_path_storage ps;
    uint32_t version;
    ngtcp2_crypto_conn_ref conn_ref;
    int handshake_completed;
    int http3_bound;

    uint8_t send_buf[65536];
    h3_stream_state *current_stream;
    int connection_closed;

    ziserver_quic_summary summary;
};

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static void  rand_cb(uint8_t *dest, size_t destlen, const ngtcp2_rand_ctx *ctx);
static int   get_new_conn_id_cb(ngtcp2_conn *conn, ngtcp2_cid *cid,
                                 uint8_t *token, size_t cidlen, void *user_data);
static int   recv_stream_data_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream_id,
                                  uint64_t offset, const uint8_t *data, size_t datalen,
                                  void *user_data, void *stream_user_data);
static int   stream_open_cb(ngtcp2_conn *conn, int64_t stream_id, void *user_data);
static int   stream_close_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream_id,
                              uint64_t app_error_code, void *user_data, void *stream_user_data);
static int   handshake_completed_cb(ngtcp2_conn *conn, void *user_data);
static ngtcp2_conn *get_conn_cb(ngtcp2_crypto_conn_ref *conn_ref);

// HTTP/3 callbacks
static int h3_begin_headers_cb(nghttp3_conn *conn, int64_t stream_id, void *user_data,
                                void *stream_user_data);
static int h3_recv_header_cb(nghttp3_conn *conn, int64_t stream_id, int32_t token,
                              nghttp3_rcbuf *name, nghttp3_rcbuf *value, uint8_t flags,
                              void *user_data, void *stream_user_data);
static int h3_end_headers_cb(nghttp3_conn *conn, int64_t stream_id, int fin,
                              void *user_data, void *stream_user_data);
static int h3_recv_data_cb(nghttp3_conn *conn, int64_t stream_id, const uint8_t *data,
                            size_t datalen, void *user_data, void *stream_user_data);
static int h3_deferred_consume_cb(nghttp3_conn *conn, int64_t stream_id, size_t nconsumed,
                                   void *user_data, void *stream_user_data);
static int h3_stop_sending_cb(nghttp3_conn *conn, int64_t stream_id, uint64_t app_error_code,
                               void *user_data, void *stream_user_data);

// Helpers
static int  write_quic_packet(quic_session *s);
static int  dispatch_request(quic_session *s, h3_stream_state *ss);
static int  send_http3_response(quic_session *s, int64_t stream_id, int status,
                                 const char *body, size_t body_len);
static char *z_strndup(const char *src, size_t n);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
const char *ziserver_nghttp3_version_text(void) {
    return "ngtcp2/" NGTCP2_VERSION " nghttp3/" NGHTTP3_VERSION;
}

int ziserver_nghttp3_serve(
    void *userdata,
    ziserver_quic_read_fn read_fn,
    ziserver_quic_write_fn write_fn,
    ziserver_h3_dispatch_fn dispatch_fn,
    ziserver_h3_release_fn release_fn,
    void *ssl_ctx_ptr,
    size_t max_header_bytes,
    size_t max_body_bytes,
    size_t max_requests,
    ziserver_quic_summary *summary
) {
    quic_session *s = (quic_session *)calloc(1, sizeof(quic_session));
    if (!s) return -1;

    s->userdata = userdata;
    s->read_fn = read_fn;
    s->write_fn = write_fn;
    s->dispatch_fn = dispatch_fn;
    s->release_fn = release_fn;
    s->max_header_bytes = max_header_bytes ? max_header_bytes : H3_MAX_HEADER_BYTES;
    s->max_body_bytes = max_body_bytes ? max_body_bytes : 65536;
    s->max_requests = max_requests ? max_requests : 100;
    s->ssl_ctx = (SSL_CTX *)ssl_ctx_ptr;
    s->conn_ref.get_conn = get_conn_cb;
    s->conn_ref.user_data = s;
    s->version = NGTCP2_PROTO_VER_V1;

    // Event loop
    while (!s->connection_closed) {
        uint8_t buf[65536];
        struct sockaddr_storage sa;
        size_t salen = sizeof(sa);
        int nread = s->read_fn(s->userdata, buf, sizeof(buf), &sa, &salen);
        if (nread < 0) continue;
        if (nread == 0) continue;
        fprintf(stderr, "[QUIC] recv %d bytes from port %d\n", nread,
                (salen >= 2) ? (int)((uint16_t)(((uint8_t *)&sa)[2]) << 8 | ((uint8_t *)&sa)[3]) : 0);

        // --- First QUIC Initial packet: create connection ---
        if (s->quic_conn == NULL) {
            ngtcp2_version_cid vc;
            int ret = ngtcp2_pkt_decode_version_cid(
                &vc, buf, (size_t)nread, SERVER_SCID_LEN);
            if (ret != 0) continue;

            fprintf(stderr, "[QUIC] new conn ver=%d dcidlen=%d scidlen=%d\n",
                    vc.version, (int)vc.dcidlen, (int)vc.scidlen);

            uint32_t packet_version = vc.version;
            ngtcp2_cid dcid, scid;
            ngtcp2_cid_init(&dcid, vc.dcid, vc.dcidlen);
            ngtcp2_cid_init(&scid, vc.scid, vc.scidlen);

            if (packet_version != NGTCP2_PROTO_VER_V1) {
                uint8_t vn_buf[256];
                uint32_t supported[] = { NGTCP2_PROTO_VER_V1 };
                ngtcp2_ssize vnlen = ngtcp2_pkt_write_version_negotiation(
                    vn_buf, sizeof(vn_buf), (uint8_t)(nread & 0xff),
                    dcid.data, dcid.datalen, scid.data, scid.datalen,
                    supported, 1);
                if (vnlen > 0) {
                    s->write_fn(s->userdata, vn_buf, (size_t)vnlen, NULL, 0);
                }
                continue;
            }

            s->version = packet_version;

            // Initialize path storage with client remote + local loopback placeholder
            {
                struct sockaddr_in local4 = {0};
                local4.sin_family = AF_INET;
                ngtcp2_path_storage_init(&s->ps,
                    (ngtcp2_sockaddr *)&local4, sizeof(local4),
                    (ngtcp2_sockaddr *)&sa, (ngtcp2_socklen)salen, NULL);
            }

            // --- ngtcp2 callbacks ---
            ngtcp2_callbacks callbacks;
            memset(&callbacks, 0, sizeof(callbacks));
            callbacks.recv_client_initial = ngtcp2_crypto_recv_client_initial_cb;
            callbacks.recv_crypto_data     = ngtcp2_crypto_recv_crypto_data_cb;
            callbacks.encrypt              = ngtcp2_crypto_encrypt_cb;
            callbacks.decrypt              = ngtcp2_crypto_decrypt_cb;
            callbacks.hp_mask              = ngtcp2_crypto_hp_mask_cb;
            callbacks.get_new_connection_id = get_new_conn_id_cb;
            callbacks.update_key            = ngtcp2_crypto_update_key_cb;
            callbacks.delete_crypto_aead_ctx  = ngtcp2_crypto_delete_crypto_aead_ctx_cb;
            callbacks.delete_crypto_cipher_ctx = ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
            callbacks.get_path_challenge_data = ngtcp2_crypto_get_path_challenge_data_cb;
            callbacks.recv_stream_data     = recv_stream_data_cb;
            callbacks.stream_open          = stream_open_cb;
            callbacks.stream_close         = stream_close_cb;
            callbacks.handshake_completed  = handshake_completed_cb;
            callbacks.rand                 = rand_cb;

            // --- ngtcp2 settings ---
            ngtcp2_settings settings;
            memset(&settings, 0, sizeof(settings));
            settings.max_tx_udp_payload_size = 1200;
            settings.initial_rtt = NGTCP2_DEFAULT_INITIAL_RTT;

            // --- Transport parameters ---
            ngtcp2_transport_params params;
            memset(&params, 0, sizeof(params));
            params.initial_max_stream_data_bidi_local  = 1024 * 1024;
            params.initial_max_stream_data_bidi_remote = 1024 * 1024;
            params.initial_max_stream_data_uni          = 1024 * 1024;
            params.initial_max_data                     = 4 * 1024 * 1024;
            params.initial_max_streams_bidi             = 100;
            params.initial_max_streams_uni              = 3;
            params.max_idle_timeout                     = 30 * NGTCP2_SECONDS;
            params.active_connection_id_limit           = 8;
            params.initial_scid_present                 = 0;
            params.original_dcid_present                = 1;
            memcpy(&params.original_dcid, &dcid, sizeof(dcid));

            ret = ngtcp2_conn_server_new_versioned(
                &s->quic_conn, &dcid, &scid, &s->ps.path,
                s->version,
                NGTCP2_CALLBACKS_VERSION, &callbacks,
                NGTCP2_SETTINGS_VERSION, &settings,
                NGTCP2_TRANSPORT_PARAMS_VERSION, &params,
                NULL, s);
            if (ret != 0) {
                fprintf(stderr, "ngtcp2_conn_server_new: %s\n", ngtcp2_strerror(ret));
                goto done;
            }
            // --- Set up TLS (QUIC via OpenSSL) ---
            if (s->ssl_ctx) {
                SSL *ssl = SSL_new(s->ssl_ctx);
                if (!ssl) {                    goto done;
                }
                SSL_set_app_data(ssl, &s->conn_ref);
                // QUIC requires TLS 1.3
                SSL_set_min_proto_version(ssl, TLS1_3_VERSION);                if (ngtcp2_crypto_ossl_configure_server_session(ssl) != 0) {                    SSL_free(ssl);
                    goto done;
                }                ngtcp2_crypto_ossl_ctx *ossl_ctx;
                if (ngtcp2_crypto_ossl_ctx_new(&ossl_ctx, ssl) != 0) {                    SSL_free(ssl);
                    goto done;
                }
                ngtcp2_conn_set_tls_native_handle(s->quic_conn, ossl_ctx);            } else {            }

            // --- nghttp3 callbacks ---
            nghttp3_callbacks h3_callbacks;
            memset(&h3_callbacks, 0, sizeof(h3_callbacks));
            h3_callbacks.deferred_consume = h3_deferred_consume_cb;
            h3_callbacks.begin_headers    = h3_begin_headers_cb;
            h3_callbacks.recv_header      = h3_recv_header_cb;
            h3_callbacks.end_headers      = h3_end_headers_cb;
            h3_callbacks.recv_data        = h3_recv_data_cb;
            h3_callbacks.stop_sending     = h3_stop_sending_cb;

            // --- nghttp3 settings ---
            nghttp3_settings h3_settings;
            memset(&h3_settings, 0, sizeof(h3_settings));
            h3_settings.max_field_section_size       = s->max_header_bytes;
            h3_settings.qpack_max_dtable_capacity    = 4096;
            h3_settings.qpack_blocked_streams        = 100;

            ret = nghttp3_conn_server_new_versioned(
                &s->http3_conn,
                NGHTTP3_CALLBACKS_VERSION, &h3_callbacks,
                NGHTTP3_SETTINGS_VERSION, &h3_settings,
                NULL, s);
            if (ret != 0) {
                fprintf(stderr, "nghttp3_conn_server_new: %d\n", ret);
                goto done;
            }
        }

        // --- Feed datagram to QUIC ---
        {
            ngtcp2_pkt_info pi;
            memset(&pi, 0, sizeof(pi));
            int ret = ngtcp2_conn_read_pkt_versioned(
                s->quic_conn, &s->ps.path,
                NGTCP2_PKT_INFO_VERSION, &pi,
                buf, (size_t)nread, 0);
            if (ret != 0) {
                if (ret == NGTCP2_ERR_RETRY || ret == NGTCP2_ERR_DROP_CONN) {                    goto done;
                }                write_quic_packet(s);
                goto done;
            }
        }

        write_quic_packet(s);
    }

done:
    if (s->quic_conn) write_quic_packet(s);

    if (summary) *summary = s->summary;

    if (s->current_stream) {
        free(s->current_stream->method);
        free(s->current_stream->path);
        free(s->current_stream->authority);
        free(s->current_stream->header_buf);
        free(s->current_stream->body);
        free(s->current_stream);
    }
    if (s->http3_conn)  nghttp3_conn_del(s->http3_conn);
    if (s->quic_conn)   ngtcp2_conn_del(s->quic_conn);
    free(s);

    return 0;
}

// ---------------------------------------------------------------------------
// ngtcp2 callbacks
// ---------------------------------------------------------------------------
static void rand_cb(uint8_t *dest, size_t destlen, const ngtcp2_rand_ctx *ctx) {
    (void)ctx;
    RAND_bytes(dest, (int)destlen);
}

static int get_new_conn_id_cb(ngtcp2_conn *conn, ngtcp2_cid *cid,
                               uint8_t *token, size_t cidlen, void *user_data) {
    (void)conn; (void)user_data;
    RAND_bytes(cid->data, (int)cidlen);
    cid->datalen = cidlen;
    RAND_bytes(token, NGTCP2_STATELESS_RESET_TOKENLEN);
    return 0;
}

static int handshake_completed_cb(ngtcp2_conn *conn, void *user_data) {
    quic_session *s = (quic_session *)user_data;
    s->handshake_completed = 1;
    (void)conn;
    return 0;
}

static ngtcp2_conn *get_conn_cb(ngtcp2_crypto_conn_ref *conn_ref) {
    return ((quic_session *)conn_ref->user_data)->quic_conn;
}

static int stream_open_cb(ngtcp2_conn *conn, int64_t stream_id, void *user_data) {
    quic_session *s = (quic_session *)user_data;
    if (!s->http3_conn) return 0;

    // Bind unidirectional control streams
    if (stream_id == 2) {
        nghttp3_conn_bind_control_stream(s->http3_conn, stream_id);
    } else if (stream_id == 6) {
        nghttp3_conn_bind_qpack_streams(s->http3_conn, stream_id, 10);
    }
    (void)conn;
    return 0;
}

static int stream_close_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream_id,
                            uint64_t app_error_code, void *user_data,
                            void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)conn;
    (void)flags;
    (void)app_error_code;
    (void)stream_user_data;

    if (s->current_stream && s->current_stream->stream_id == stream_id) {
        free(s->current_stream->method);
        free(s->current_stream->path);
        free(s->current_stream->authority);
        free(s->current_stream->header_buf);
        free(s->current_stream->body);
        free(s->current_stream);
        s->current_stream = NULL;
    }
    return 0;
}

static int recv_stream_data_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream_id,
                                uint64_t offset, const uint8_t *data, size_t datalen,
                                void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    int fin = (flags & NGTCP2_STREAM_DATA_FLAG_FIN) != 0;
    (void)conn;
    (void)offset;
    (void)stream_user_data;

    if (!s->http3_conn) return 0;

    if (datalen > 0 || fin) {
        nghttp3_ssize nconsumed = nghttp3_conn_read_stream(
            s->http3_conn, stream_id, data, datalen, fin);
        if (nconsumed < 0) {
            ngtcp2_conn_shutdown_stream(conn, 0, stream_id,
                                        NGHTTP3_H3_GENERAL_PROTOCOL_ERROR);
            return 0;
        }
        ngtcp2_conn_extend_max_stream_offset(conn, stream_id, (uint64_t)nconsumed);
        ngtcp2_conn_extend_max_offset(conn, (uint64_t)nconsumed);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// nghttp3 callbacks
// ---------------------------------------------------------------------------
static int h3_begin_headers_cb(nghttp3_conn *conn, int64_t stream_id,
                                void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)conn;
    (void)stream_user_data;

    if (s->current_stream) {
        free(s->current_stream->method);
        free(s->current_stream->path);
        free(s->current_stream->authority);
        free(s->current_stream->header_buf);
        free(s->current_stream->body);
        free(s->current_stream);
    }

    h3_stream_state *ss = (h3_stream_state *)calloc(1, sizeof(h3_stream_state));
    if (!ss) return NGHTTP3_ERR_NOMEM;
    ss->stream_id = stream_id;
    ss->header_buf_cap = 4096;
    ss->header_buf = (char *)malloc(ss->header_buf_cap);
    if (!ss->header_buf) { free(ss); return NGHTTP3_ERR_NOMEM; }
    s->current_stream = ss;
    return 0;
}

static int h3_recv_header_cb(nghttp3_conn *conn, int64_t stream_id, int32_t token,
                              nghttp3_rcbuf *name, nghttp3_rcbuf *value, uint8_t flags,
                              void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    h3_stream_state *ss = s->current_stream;
    (void)conn; (void)flags; (void)stream_user_data;
    if (!ss || ss->stream_id != stream_id) return 0;

    nghttp3_vec nv = nghttp3_rcbuf_get_buf(name);
    nghttp3_vec vv = nghttp3_rcbuf_get_buf(value);

    if (token == NGHTTP3_QPACK_TOKEN__METHOD) {
        free(ss->method);
        ss->method = z_strndup((const char *)vv.base, vv.len);
        ss->method_len = vv.len;
    } else if (token == NGHTTP3_QPACK_TOKEN__PATH) {
        free(ss->path);
        ss->path = z_strndup((const char *)vv.base, vv.len);
        ss->path_len = vv.len;
    } else if (token == NGHTTP3_QPACK_TOKEN__AUTHORITY) {
        free(ss->authority);
        ss->authority = z_strndup((const char *)vv.base, vv.len);
        ss->authority_len = vv.len;
    }

    // Append "name: value\n" to header buffer
    size_t needed = ss->header_buf_len + nv.len + 2 + vv.len + 1;
    if (needed > ss->header_buf_cap) {
        size_t new_cap = ss->header_buf_cap * 2;
        if (new_cap < needed) new_cap = needed;
        if (new_cap > s->max_header_bytes) return NGHTTP3_ERR_H3_EXCESSIVE_LOAD;
        char *nb = (char *)realloc(ss->header_buf, new_cap);
        if (!nb) return NGHTTP3_ERR_NOMEM;
        ss->header_buf = nb;
        ss->header_buf_cap = new_cap;
    }
    memcpy(ss->header_buf + ss->header_buf_len, nv.base, nv.len);
    ss->header_buf_len += nv.len;
    ss->header_buf[ss->header_buf_len++] = ':';
    ss->header_buf[ss->header_buf_len++] = ' ';
    memcpy(ss->header_buf + ss->header_buf_len, vv.base, vv.len);
    ss->header_buf_len += vv.len;
    ss->header_buf[ss->header_buf_len++] = '\n';
    return 0;
}

static int h3_end_headers_cb(nghttp3_conn *conn, int64_t stream_id, int fin,
                              void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    h3_stream_state *ss = s->current_stream;
    (void)conn; (void)stream_user_data;
    if (!ss || ss->stream_id != stream_id) return 0;
    ss->headers_complete = 1;
    if (fin && !ss->dispatched) dispatch_request(s, ss);
    return 0;
}

static int h3_recv_data_cb(nghttp3_conn *conn, int64_t stream_id, const uint8_t *data,
                            size_t datalen, void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    h3_stream_state *ss = s->current_stream;
    (void)conn; (void)stream_user_data;
    if (!ss || ss->stream_id != stream_id) return 0;

    size_t new_len = ss->body_len + datalen;
    if (new_len > s->max_body_bytes) return NGHTTP3_ERR_H3_EXCESSIVE_LOAD;
    if (new_len > ss->body_cap) {
        size_t new_cap = ss->body_cap ? ss->body_cap * 2 : 4096;
        if (new_cap < new_len) new_cap = new_len;
        char *nb = (char *)realloc(ss->body, new_cap);
        if (!nb) return NGHTTP3_ERR_NOMEM;
        ss->body = nb;
        ss->body_cap = new_cap;
    }
    memcpy(ss->body + ss->body_len, data, datalen);
    ss->body_len = new_len;
    return 0;
}

static int h3_deferred_consume_cb(nghttp3_conn *conn, int64_t stream_id, size_t nconsumed,
                                   void *user_data, void *stream_user_data) {
    (void)conn; (void)stream_id; (void)nconsumed; (void)user_data; (void)stream_user_data;
    return 0;
}

static int h3_stop_sending_cb(nghttp3_conn *conn, int64_t stream_id, uint64_t app_error_code,
                               void *user_data, void *stream_user_data) {
    (void)conn; (void)stream_id; (void)app_error_code; (void)user_data; (void)stream_user_data;
    return 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static int write_quic_packet(quic_session *s) {
    if (!s->quic_conn) return 0;
    ngtcp2_path_storage ps;
    ngtcp2_path_storage_zero(&ps);
    for (;;) {
        ngtcp2_pkt_info pi;
        ngtcp2_ssize nw = ngtcp2_conn_writev_stream(
            s->quic_conn, &ps.path, &pi, s->send_buf, sizeof(s->send_buf), NULL,
            NGTCP2_WRITE_STREAM_FLAG_MORE, -1, NULL, 0, 0);
        if (nw <= 0) break;
        s->write_fn(s->userdata, s->send_buf, (size_t)nw, NULL, 0);
    }
    return 0;
}

static int dispatch_request(quic_session *s, h3_stream_state *ss) {
    if (s->request_count >= s->max_requests) {
        send_http3_response(s, ss->stream_id, 503,
                            "{\"error\":\"too many requests\"}", 27);
        return 0;
    }
    ss->dispatched = 1;
    s->request_count++;
    s->summary.requests = s->request_count;
    if ((uint32_t)ss->stream_id > s->summary.highest_stream_id)
        s->summary.highest_stream_id = (uint32_t)ss->stream_id;

    ziserver_h3_request req;
    memset(&req, 0, sizeof(req));
    req.method_ptr    = ss->method    ? ss->method    : "GET";
    req.method_len    = ss->method_len ? ss->method_len : 3;
    req.path_ptr      = ss->path      ? ss->path      : "/";
    req.path_len      = ss->path_len  ? ss->path_len  : 1;
    req.authority_ptr = ss->authority  ? ss->authority  : "localhost";
    req.authority_len = ss->authority_len ? ss->authority_len : 9;
    req.headers_ptr   = ss->header_buf;
    req.headers_len   = ss->header_buf_len;
    req.body_ptr      = ss->body;
    req.body_len      = ss->body_len;

    int ret = s->dispatch_fn(s->userdata, &req, NULL);
    send_http3_response(s, ss->stream_id, ret == 0 ? 200 : 500,
                        ret == 0 ? "{\"status\":\"ok\"}" : "{\"error\":\"internal error\"}",
                        ret == 0 ? 15 : 26);
    return 0;
}

// Body read context — used by body_read_cb to serve static response data.
typedef struct {
    const char *body;
    size_t body_len;
} h3_body_read_ctx;

static nghttp3_ssize h3_body_read_cb(nghttp3_conn *conn, int64_t stream_id,
                                      nghttp3_vec *vec, size_t veccnt,
                                      uint32_t *pflags, void *user_data,
                                      void *stream_user_data) {
    (void)conn; (void)stream_id; (void)stream_user_data;
    h3_body_read_ctx *ctx = (h3_body_read_ctx *)user_data;
    if (ctx && ctx->body && ctx->body_len > 0 && veccnt > 0) {
        vec[0].base = (uint8_t *)ctx->body;
        vec[0].len = ctx->body_len;
        *pflags |= NGHTTP3_DATA_FLAG_EOF;
        return (nghttp3_ssize)ctx->body_len;
    }
    *pflags |= NGHTTP3_DATA_FLAG_EOF;
    return 0;
}

static int send_http3_response(quic_session *s, int64_t stream_id, int status,
                                const char *body, size_t body_len) {
    if (!s->http3_conn || !s->quic_conn) return -1;

    char status_str[16];
    snprintf(status_str, sizeof(status_str), "%d", status);

    nghttp3_nv headers[] = {
        {.name = (uint8_t *)":status",       .namelen = 7,
         .value = (uint8_t *)status_str,     .valuelen = strlen(status_str),
         .flags = NGHTTP3_NV_FLAG_NONE},
        {.name = (uint8_t *)"server",        .namelen = 6,
         .value = (uint8_t *)"ZiServer/0.4", .valuelen = 13,
         .flags = NGHTTP3_NV_FLAG_NONE},
        {.name = (uint8_t *)"content-type",  .namelen = 12,
         .value = (uint8_t *)"application/json", .valuelen = 16,
         .flags = NGHTTP3_NV_FLAG_NONE},
    };

    nghttp3_data_reader dr;
    memset(&dr, 0, sizeof(dr));
    dr.read_data = h3_body_read_cb;
    h3_body_read_ctx body_ctx = { .body = body, .body_len = body_len };

    int ret = nghttp3_conn_submit_response(
        s->http3_conn, stream_id, headers, 3,
        (body && body_len > 0) ? &dr : NULL);
    if (ret != 0) return -1;

    // Flush nghttp3 → ngtcp2
    for (;;) {
        nghttp3_vec vecs[16];
        int64_t sid;
        int fin;
        nghttp3_ssize nvecs = nghttp3_conn_writev_stream(
            s->http3_conn, &sid, &fin, vecs, 16);
        if (nvecs <= 0) break;
        for (nghttp3_ssize i = 0; i < nvecs; i++) {
            ngtcp2_vec qv = { .base = vecs[i].base, .len = vecs[i].len };
            ngtcp2_conn_writev_stream(
                s->quic_conn, NULL, NULL, NULL, 0, NULL,
                NGTCP2_WRITE_STREAM_FLAG_MORE,
                sid, &qv, 1, 0);
        }
    }
    write_quic_packet(s);
    return 0;
}

static char *z_strndup(const char *src, size_t n) {
    char *d = (char *)malloc(n + 1);
    if (!d) return NULL;
    memcpy(d, src, n);
    d[n] = '\0';
    return d;
}

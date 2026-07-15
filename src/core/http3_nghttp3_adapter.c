// Experimental single-connection HTTP/3 server adapter.
// ngtcp2 owns QUIC state; nghttp3 owns RFC 9114/QPACK state; Zig owns routing.

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#endif

#include <nghttp3/nghttp3.h>
#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_ossl.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ZISERVER_H3_MAX_HEADERS 64
#define ZISERVER_CAPTURE_HEADERS 24
#define ZISERVER_SERVER_CID_LEN 18
#define ZISERVER_READ_TICK_MS 100

typedef int (*ziserver_quic_read_fn)(void *, uint8_t *, size_t, void *, size_t *, uint32_t);
typedef int (*ziserver_quic_write_fn)(void *, const uint8_t *, size_t, const void *, size_t);
typedef int (*ziserver_h3_dispatch_fn)(void *, const void *, void *);
typedef void (*ziserver_h3_release_fn)(void *, void *);
typedef int (*ziserver_stop_fn)(void *);
typedef uint64_t (*ziserver_now_fn)(void *);

typedef struct {
    const uint8_t *name_ptr;
    size_t name_len;
    const uint8_t *value_ptr;
    size_t value_len;
} ziserver_header;

typedef struct {
    uint16_t status;
    const uint8_t *content_type_ptr;
    size_t content_type_len;
    size_t content_length;
    uint8_t *body_ptr;
    size_t body_len;
    const uint8_t *cache_ptr;
    size_t cache_len;
    ziserver_header headers[ZISERVER_CAPTURE_HEADERS];
    size_t headers_len;
    uint8_t streaming;
    uint8_t content_length_known;
} ziserver_capture;

typedef struct {
    const uint8_t *method_ptr;
    size_t method_len;
    const uint8_t *path_ptr;
    size_t path_len;
    const uint8_t *authority_ptr;
    size_t authority_len;
    const ziserver_header *headers_ptr;
    size_t headers_len;
    const uint8_t *body_ptr;
    size_t body_len;
    uint16_t error_status;
} ziserver_h3_request;

typedef struct {
    uint64_t requests;
    uint32_t highest_stream_id;
    uint8_t goaway_sent;
} ziserver_quic_summary;

typedef struct h3_stream_state h3_stream_state;
struct h3_stream_state {
    h3_stream_state *next;
    int64_t stream_id;
    uint8_t *method;
    size_t method_len;
    uint8_t *path;
    size_t path_len;
    uint8_t *authority;
    size_t authority_len;
    ziserver_header headers[ZISERVER_H3_MAX_HEADERS];
    size_t headers_len;
    size_t header_bytes;
    uint8_t *body;
    size_t body_len;
    size_t body_cap;
    uint16_t error_status;
    int method_seen;
    int path_seen;
    int authority_seen;
    int scheme_seen;
    int headers_complete;
    int dispatched;
    int capture_owned;
    int body_provided;
    char status_text[4];
    char length_text[32];
    ziserver_capture capture;
};

typedef struct {
    void *userdata;
    ziserver_quic_read_fn read_fn;
    ziserver_quic_write_fn write_fn;
    ziserver_h3_dispatch_fn dispatch_fn;
    ziserver_h3_release_fn release_fn;
    ziserver_stop_fn stop_fn;
    ziserver_now_fn now_fn;
    size_t max_header_bytes;
    size_t max_body_bytes;
    size_t max_requests;
    size_t request_count;
    ngtcp2_conn *quic_conn;
    nghttp3_conn *http3_conn;
    SSL *ssl;
    ngtcp2_crypto_ossl_ctx *ossl_ctx;
    ngtcp2_crypto_conn_ref conn_ref;
    ngtcp2_path_storage path;
    struct sockaddr_storage peer_addr;
    size_t peer_addrlen;
    int peer_set;
    int h3_bound;
    int closing;
    uint8_t send_buf[65536];
    h3_stream_state *streams;
    ziserver_quic_summary summary;
} quic_session;

static int flush_packets(quic_session *s);
static int dispatch_request(quic_session *s, h3_stream_state *stream);

static uint8_t *dup_bytes(const uint8_t *src, size_t len) {
    uint8_t *copy = (uint8_t *)malloc(len + 1);
    if (!copy) return NULL;
    if (len) memcpy(copy, src, len);
    copy[len] = 0;
    return copy;
}

static int sockaddr_equal(const struct sockaddr_storage *a, size_t alen,
                          const struct sockaddr_storage *b, size_t blen) {
    if (alen != blen || alen < sizeof(a->ss_family)) return 0;
    if (a->ss_family != b->ss_family) return 0;
    if (a->ss_family == AF_INET) {
        const struct sockaddr_in *aa = (const struct sockaddr_in *)a;
        const struct sockaddr_in *bb = (const struct sockaddr_in *)b;
        return aa->sin_port == bb->sin_port && aa->sin_addr.s_addr == bb->sin_addr.s_addr;
    }
    if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *aa = (const struct sockaddr_in6 *)a;
        const struct sockaddr_in6 *bb = (const struct sockaddr_in6 *)b;
        return aa->sin6_port == bb->sin6_port &&
               aa->sin6_scope_id == bb->sin6_scope_id &&
               memcmp(&aa->sin6_addr, &bb->sin6_addr, sizeof(aa->sin6_addr)) == 0;
    }
    return 0;
}

static h3_stream_state *find_stream(quic_session *s, int64_t stream_id) {
    h3_stream_state *stream = s->streams;
    while (stream && stream->stream_id != stream_id) stream = stream->next;
    return stream;
}

static void free_stream(quic_session *s, h3_stream_state *stream) {
    if (!stream) return;
    if (stream->capture_owned) s->release_fn(s->userdata, &stream->capture);
    free(stream->method);
    free(stream->path);
    free(stream->authority);
    for (size_t i = 0; i < stream->headers_len; ++i) {
        free((void *)stream->headers[i].name_ptr);
        free((void *)stream->headers[i].value_ptr);
    }
    free(stream->body);
    free(stream);
}

static void remove_stream(quic_session *s, int64_t stream_id) {
    h3_stream_state **cursor = &s->streams;
    while (*cursor) {
        if ((*cursor)->stream_id == stream_id) {
            h3_stream_state *stream = *cursor;
            *cursor = stream->next;
            free_stream(s, stream);
            return;
        }
        cursor = &(*cursor)->next;
    }
}

static void free_all_streams(quic_session *s) {
    while (s->streams) {
        h3_stream_state *stream = s->streams;
        s->streams = stream->next;
        free_stream(s, stream);
    }
}

static int setup_http3_streams(quic_session *s) {
    if (s->h3_bound) return 0;
    if (ngtcp2_conn_get_streams_uni_left2(s->quic_conn) < 3) return -1;
    int64_t control_id, encoder_id, decoder_id;
    if (ngtcp2_conn_open_uni_stream(s->quic_conn, &control_id, NULL) != 0 ||
        ngtcp2_conn_open_uni_stream(s->quic_conn, &encoder_id, NULL) != 0 ||
        ngtcp2_conn_open_uni_stream(s->quic_conn, &decoder_id, NULL) != 0) return -1;
    if (nghttp3_conn_bind_control_stream(s->http3_conn, control_id) != 0 ||
        nghttp3_conn_bind_qpack_streams(s->http3_conn, encoder_id, decoder_id) != 0) return -1;
    s->h3_bound = 1;
    return 0;
}

static void rand_cb(uint8_t *dest, size_t destlen, const ngtcp2_rand_ctx *ctx) {
    (void)ctx;
    if (RAND_bytes(dest, (int)destlen) != 1) memset(dest, 0, destlen);
}

static int get_new_conn_id_cb(ngtcp2_conn *conn, ngtcp2_cid *cid,
                              uint8_t *token, size_t cidlen, void *user_data) {
    (void)conn;
    (void)user_data;
    if (RAND_bytes(cid->data, (int)cidlen) != 1 ||
        RAND_bytes(token, NGTCP2_STATELESS_RESET_TOKENLEN) != 1) return NGTCP2_ERR_CALLBACK_FAILURE;
    cid->datalen = cidlen;
    return 0;
}

static ngtcp2_conn *get_conn_cb(ngtcp2_crypto_conn_ref *ref) {
    return ((quic_session *)ref->user_data)->quic_conn;
}

static int handshake_completed_cb(ngtcp2_conn *conn, void *user_data) {
    (void)conn;
    return setup_http3_streams((quic_session *)user_data) == 0 ? 0 : NGTCP2_ERR_CALLBACK_FAILURE;
}

static int stream_close_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream_id,
                           uint64_t app_error_code, void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)conn;
    (void)flags;
    (void)stream_user_data;
    if (s->http3_conn) {
        uint64_t code = app_error_code ? app_error_code : NGHTTP3_H3_NO_ERROR;
        int rv = nghttp3_conn_close_stream(s->http3_conn, stream_id, code);
        if (rv != 0 && rv != NGHTTP3_ERR_STREAM_NOT_FOUND) return NGTCP2_ERR_CALLBACK_FAILURE;
    }
    remove_stream(s, stream_id);
    return 0;
}

static int recv_stream_data_cb(ngtcp2_conn *conn, uint32_t flags, int64_t stream_id,
                               uint64_t offset, const uint8_t *data, size_t datalen,
                               void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)offset;
    (void)stream_user_data;
    if (!s->http3_conn) return 0;
    int fin = (flags & NGTCP2_STREAM_DATA_FLAG_FIN) != 0;
    nghttp3_ssize consumed = nghttp3_conn_read_stream2(
        s->http3_conn, stream_id, data, datalen, fin, s->now_fn(s->userdata));
    if (consumed < 0) return NGTCP2_ERR_CALLBACK_FAILURE;
    ngtcp2_conn_extend_max_stream_offset(conn, stream_id, (uint64_t)consumed);
    ngtcp2_conn_extend_max_offset(conn, (uint64_t)consumed);
    return 0;
}

static int h3_begin_headers_cb(nghttp3_conn *conn, int64_t stream_id,
                               void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)stream_user_data;
    if (find_stream(s, stream_id)) return NGHTTP3_ERR_H3_GENERAL_PROTOCOL_ERROR;
    h3_stream_state *stream = (h3_stream_state *)calloc(1, sizeof(*stream));
    if (!stream) return NGHTTP3_ERR_NOMEM;
    stream->stream_id = stream_id;
    stream->next = s->streams;
    s->streams = stream;
    if (nghttp3_conn_set_stream_user_data(conn, stream_id, stream) != 0) {
        remove_stream(s, stream_id);
        return NGHTTP3_ERR_H3_GENERAL_PROTOCOL_ERROR;
    }
    return 0;
}

static int replace_pseudo(uint8_t **target, size_t *target_len, int *seen,
                          const uint8_t *value, size_t value_len) {
    if (*seen) return -1;
    uint8_t *copy = dup_bytes(value, value_len);
    if (!copy) return -2;
    *target = copy;
    *target_len = value_len;
    *seen = 1;
    return 0;
}

static int h3_recv_header_cb(nghttp3_conn *conn, int64_t stream_id, int32_t token,
                             nghttp3_rcbuf *name, nghttp3_rcbuf *value, uint8_t flags,
                             void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    h3_stream_state *stream = (h3_stream_state *)stream_user_data;
    (void)conn;
    (void)stream_id;
    (void)flags;
    if (!stream) return NGHTTP3_ERR_H3_GENERAL_PROTOCOL_ERROR;
    nghttp3_vec n = nghttp3_rcbuf_get_buf(name);
    nghttp3_vec v = nghttp3_rcbuf_get_buf(value);
    if (n.len > s->max_header_bytes ||
        v.len > s->max_header_bytes - n.len ||
        stream->header_bytes > s->max_header_bytes - n.len - v.len) {
        stream->error_status = 431;
        return 0;
    }
    stream->header_bytes += n.len + v.len;

    int rv = 0;
    switch (token) {
    case NGHTTP3_QPACK_TOKEN__METHOD:
        rv = replace_pseudo(&stream->method, &stream->method_len, &stream->method_seen, v.base, v.len);
        break;
    case NGHTTP3_QPACK_TOKEN__PATH:
        rv = replace_pseudo(&stream->path, &stream->path_len, &stream->path_seen, v.base, v.len);
        break;
    case NGHTTP3_QPACK_TOKEN__AUTHORITY:
        rv = replace_pseudo(&stream->authority, &stream->authority_len, &stream->authority_seen, v.base, v.len);
        break;
    case NGHTTP3_QPACK_TOKEN__SCHEME:
        if (stream->scheme_seen || v.len != 5 || memcmp(v.base, "https", 5) != 0) rv = -1;
        stream->scheme_seen = 1;
        break;
    default: {
        if (stream->headers_len == ZISERVER_H3_MAX_HEADERS) {
            stream->error_status = 431;
            return 0;
        }
        uint8_t *name_copy = dup_bytes(n.base, n.len);
        uint8_t *value_copy = dup_bytes(v.base, v.len);
        if (!name_copy || !value_copy) {
            free(name_copy);
            free(value_copy);
            return NGHTTP3_ERR_NOMEM;
        }
        stream->headers[stream->headers_len++] = (ziserver_header){
            name_copy, n.len, value_copy, v.len,
        };
        break;
    }
    }
    if (rv == -2) return NGHTTP3_ERR_NOMEM;
    if (rv != 0) stream->error_status = 400;
    return 0;
}

static int h3_end_headers_cb(nghttp3_conn *conn, int64_t stream_id, int fin,
                             void *user_data, void *stream_user_data) {
    h3_stream_state *stream = (h3_stream_state *)stream_user_data;
    (void)conn;
    (void)stream_id;
    if (!stream) return NGHTTP3_ERR_H3_GENERAL_PROTOCOL_ERROR;
    stream->headers_complete = 1;
    if (!stream->method_seen || !stream->path_seen || !stream->authority_seen || !stream->scheme_seen)
        stream->error_status = 400;
    return fin ? dispatch_request((quic_session *)user_data, stream) : 0;
}

static int h3_recv_data_cb(nghttp3_conn *conn, int64_t stream_id, const uint8_t *data,
                           size_t datalen, void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    h3_stream_state *stream = (h3_stream_state *)stream_user_data;
    (void)conn;
    (void)stream_id;
    if (!stream) return NGHTTP3_ERR_H3_GENERAL_PROTOCOL_ERROR;
    if (stream->error_status == 413) return 0;
    if (datalen > s->max_body_bytes - stream->body_len) {
        stream->error_status = 413;
        free(stream->body);
        stream->body = NULL;
        stream->body_len = stream->body_cap = 0;
        return 0;
    }
    size_t required = stream->body_len + datalen;
    if (required > stream->body_cap) {
        size_t capacity = stream->body_cap ? stream->body_cap * 2 : 4096;
        if (capacity < required) capacity = required;
        uint8_t *body = (uint8_t *)realloc(stream->body, capacity);
        if (!body) return NGHTTP3_ERR_NOMEM;
        stream->body = body;
        stream->body_cap = capacity;
    }
    if (datalen) memcpy(stream->body + stream->body_len, data, datalen);
    stream->body_len = required;
    return 0;
}

static int h3_end_stream_cb(nghttp3_conn *conn, int64_t stream_id,
                            void *user_data, void *stream_user_data) {
    (void)conn;
    (void)stream_id;
    h3_stream_state *stream = (h3_stream_state *)stream_user_data;
    return stream ? dispatch_request((quic_session *)user_data, stream) : 0;
}

static int h3_deferred_consume_cb(nghttp3_conn *conn, int64_t stream_id, size_t consumed,
                                  void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)stream_user_data;
    ngtcp2_conn_extend_max_stream_offset(s->quic_conn, stream_id, consumed);
    ngtcp2_conn_extend_max_offset(s->quic_conn, consumed);
    (void)conn;
    return 0;
}

static int h3_stop_sending_cb(nghttp3_conn *conn, int64_t stream_id, uint64_t code,
                              void *user_data, void *stream_user_data) {
    quic_session *s = (quic_session *)user_data;
    (void)conn;
    (void)stream_user_data;
    return ngtcp2_conn_shutdown_stream_read(s->quic_conn, 0, stream_id, code) == 0 ? 0 : NGHTTP3_ERR_CALLBACK_FAILURE;
}

static nghttp3_ssize response_body_read_cb(nghttp3_conn *conn, int64_t stream_id,
                                           nghttp3_vec *vec, size_t veccnt,
                                           uint32_t *flags, void *user_data,
                                           void *stream_user_data) {
    h3_stream_state *stream = (h3_stream_state *)stream_user_data;
    (void)conn;
    (void)stream_id;
    (void)user_data;
    *flags |= NGHTTP3_DATA_FLAG_EOF;
    if (!stream || stream->body_provided || stream->capture.body_len == 0 || veccnt == 0) return 0;
    stream->body_provided = 1;
    vec[0].base = stream->capture.body_ptr;
    vec[0].len = stream->capture.body_len;
    return 1;
}

static void fallback_capture(h3_stream_state *stream, uint16_t status,
                             const char *body) {
    memset(&stream->capture, 0, sizeof(stream->capture));
    stream->capture.status = status;
    stream->capture.content_type_ptr = dup_bytes((const uint8_t *)"application/json", 16);
    stream->capture.content_type_len = stream->capture.content_type_ptr ? 16 : 0;
    stream->capture.body_len = strlen(body);
    stream->capture.content_length = stream->capture.body_len;
    stream->capture.body_ptr = dup_bytes((const uint8_t *)body, stream->capture.body_len);
    if (!stream->capture.body_ptr) {
        stream->capture.body_len = 0;
        stream->capture.content_length = 0;
    }
    stream->capture.content_length_known = 1;
    stream->capture_owned = 1;
}

static int submit_response(quic_session *s, h3_stream_state *stream) {
    ziserver_capture *capture = &stream->capture;
    uint16_t status = capture->status >= 100 && capture->status <= 999 ? capture->status : 500;
    snprintf(stream->status_text, sizeof(stream->status_text), "%u", status);
    snprintf(stream->length_text, sizeof(stream->length_text), "%zu", capture->content_length);

    nghttp3_nv fields[4 + ZISERVER_CAPTURE_HEADERS];
    size_t count = 0;
#define ADD_FIELD(N, NL, V, VL) fields[count++] = (nghttp3_nv){(uint8_t *)(N), (uint8_t *)(V), (NL), (VL), NGHTTP3_NV_FLAG_NONE}
    ADD_FIELD(":status", 7, stream->status_text, strlen(stream->status_text));
    if (capture->content_type_ptr && capture->content_type_len)
        ADD_FIELD("content-type", 12, capture->content_type_ptr, capture->content_type_len);
    ADD_FIELD("content-length", 14, stream->length_text, strlen(stream->length_text));
    if (capture->cache_ptr && capture->cache_len)
        ADD_FIELD("cache-control", 13, capture->cache_ptr, capture->cache_len);
    size_t extra = capture->headers_len < ZISERVER_CAPTURE_HEADERS ? capture->headers_len : ZISERVER_CAPTURE_HEADERS;
    for (size_t i = 0; i < extra; ++i) {
        const ziserver_header *header = &capture->headers[i];
        ADD_FIELD(header->name_ptr, header->name_len, header->value_ptr, header->value_len);
    }
#undef ADD_FIELD
    nghttp3_data_reader reader = {response_body_read_cb};
    return nghttp3_conn_submit_response(s->http3_conn, stream->stream_id, fields, count,
                                        capture->body_len ? &reader : NULL);
}

static int dispatch_request(quic_session *s, h3_stream_state *stream) {
    if (stream->dispatched) return 0;
    stream->dispatched = 1;
    if (s->request_count >= s->max_requests) {
        fallback_capture(stream, 503, "{\"error\":\"request limit reached\"}\n");
        return submit_response(s, stream);
    }
    ++s->request_count;
    s->summary.requests = s->request_count;
    if ((uint64_t)stream->stream_id > s->summary.highest_stream_id)
        s->summary.highest_stream_id = (uint32_t)stream->stream_id;

    ziserver_h3_request request = {
        stream->method, stream->method_len,
        stream->path, stream->path_len,
        stream->authority, stream->authority_len,
        stream->headers, stream->headers_len,
        stream->body, stream->body_len,
        stream->error_status,
    };
    memset(&stream->capture, 0, sizeof(stream->capture));
    if (s->dispatch_fn(s->userdata, &request, &stream->capture) != 0) {
        s->release_fn(s->userdata, &stream->capture);
        fallback_capture(stream, 500, "{\"error\":\"internal server error\"}\n");
    } else {
        stream->capture_owned = 1;
    }
    return submit_response(s, stream);
}

static int flush_packets(quic_session *s) {
    if (!s->quic_conn) return 0;
    for (;;) {
        nghttp3_vec h3vec[16];
        int64_t stream_id = -1;
        int fin = 0;
        nghttp3_ssize h3count = 0;
        if (s->http3_conn && ngtcp2_conn_get_max_data_left2(s->quic_conn)) {
            h3count = nghttp3_conn_writev_stream(s->http3_conn, &stream_id, &fin, h3vec, 16);
            if (h3count < 0) return -1;
        }
        ngtcp2_pkt_info pi;
        memset(&pi, 0, sizeof(pi));
        ngtcp2_ssize accepted = -1;
        uint32_t flags = NGTCP2_WRITE_STREAM_FLAG_MORE | NGTCP2_WRITE_STREAM_FLAG_PADDING;
        if (fin) flags |= NGTCP2_WRITE_STREAM_FLAG_FIN;
        uint64_t now = s->now_fn(s->userdata);
        ngtcp2_ssize written = ngtcp2_conn_writev_stream(
            s->quic_conn, &s->path.path, &pi, s->send_buf, sizeof(s->send_buf),
            &accepted, flags, stream_id, (const ngtcp2_vec *)h3vec,
            (size_t)h3count, now);
        if (written < 0) {
            if (written == NGTCP2_ERR_WRITE_MORE) {
                if (accepted >= 0 && nghttp3_conn_add_write_offset(s->http3_conn, stream_id, (size_t)accepted) != 0)
                    return -1;
                continue;
            }
            if (written == NGTCP2_ERR_STREAM_DATA_BLOCKED) {
                if (s->http3_conn) nghttp3_conn_block_stream(s->http3_conn, stream_id);
                continue;
            }
            if (written == NGTCP2_ERR_STREAM_SHUT_WR) {
                if (s->http3_conn) nghttp3_conn_shutdown_stream_write(s->http3_conn, stream_id);
                continue;
            }
            return -1;
        }
        if (accepted >= 0 && s->http3_conn &&
            nghttp3_conn_add_write_offset(s->http3_conn, stream_id, (size_t)accepted) != 0) return -1;
        if (written == 0) break;
        if (s->write_fn(s->userdata, s->send_buf, (size_t)written,
                        &s->peer_addr, s->peer_addrlen) != 0) return -1;
        ngtcp2_conn_update_pkt_tx_time(s->quic_conn, now);
    }
    return 0;
}

static uint32_t next_read_timeout_ms(quic_session *s) {
    if (!s->quic_conn) return ZISERVER_READ_TICK_MS;
    uint64_t now = s->now_fn(s->userdata);
    uint64_t expiry = ngtcp2_conn_get_expiry2(s->quic_conn);
    if (expiry <= now) return 1;
    uint64_t millis = (expiry - now + NGTCP2_MILLISECONDS - 1) / NGTCP2_MILLISECONDS;
    if (millis == 0) millis = 1;
    if (millis > ZISERVER_READ_TICK_MS) millis = ZISERVER_READ_TICK_MS;
    return (uint32_t)millis;
}

static int initialize_connection(quic_session *s, const uint8_t *packet, size_t packet_len,
                                 const struct sockaddr_storage *peer, size_t peer_len,
                                 SSL_CTX *ssl_ctx, uint64_t initial_ts) {
    ngtcp2_pkt_hd header;
    if (ngtcp2_accept(&header, packet, packet_len) != 0 || header.type != NGTCP2_PKT_INITIAL) return 1;
    if (!ngtcp2_is_supported_version(header.version)) return 1;

    ngtcp2_cid dcid = header.scid;
    ngtcp2_cid scid;
    scid.datalen = ZISERVER_SERVER_CID_LEN;
    if (RAND_bytes(scid.data, (int)scid.datalen) != 1) return -1;

    struct sockaddr_storage local;
    memset(&local, 0, sizeof(local));
    local.ss_family = peer->ss_family;
    ngtcp2_path_storage_init(&s->path,
        (const ngtcp2_sockaddr *)&local,
        peer->ss_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in),
        (const ngtcp2_sockaddr *)peer, (ngtcp2_socklen)peer_len, NULL);

    ngtcp2_callbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.recv_client_initial = ngtcp2_crypto_recv_client_initial_cb;
    callbacks.recv_crypto_data = ngtcp2_crypto_recv_crypto_data_cb;
    callbacks.encrypt = ngtcp2_crypto_encrypt_cb;
    callbacks.decrypt = ngtcp2_crypto_decrypt_cb;
    callbacks.hp_mask = ngtcp2_crypto_hp_mask_cb;
    callbacks.get_new_connection_id = get_new_conn_id_cb;
    callbacks.update_key = ngtcp2_crypto_update_key_cb;
    callbacks.delete_crypto_aead_ctx = ngtcp2_crypto_delete_crypto_aead_ctx_cb;
    callbacks.delete_crypto_cipher_ctx = ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
    callbacks.get_path_challenge_data = ngtcp2_crypto_get_path_challenge_data_cb;
    callbacks.recv_stream_data = recv_stream_data_cb;
    callbacks.stream_close = stream_close_cb;
    callbacks.handshake_completed = handshake_completed_cb;
    callbacks.rand = rand_cb;

    ngtcp2_settings settings;
    ngtcp2_settings_default(&settings);
    settings.initial_ts = initial_ts;
    settings.handshake_timeout = 10 * NGTCP2_SECONDS;
    settings.max_tx_udp_payload_size = 1200;

    ngtcp2_transport_params params;
    ngtcp2_transport_params_default(&params);
    params.initial_max_stream_data_bidi_local = s->max_body_bytes + s->max_header_bytes;
    params.initial_max_stream_data_bidi_remote = s->max_body_bytes + s->max_header_bytes;
    params.initial_max_stream_data_uni = 256 * 1024;
    params.initial_max_data = 4 * 1024 * 1024;
    params.initial_max_streams_bidi = 128;
    params.initial_max_streams_uni = 3;
    params.max_idle_timeout = 30 * NGTCP2_SECONDS;
    params.active_connection_id_limit = 8;
    params.original_dcid = header.dcid;
    params.original_dcid_present = 1;

    int rv = ngtcp2_conn_server_new(&s->quic_conn, &dcid, &scid, &s->path.path,
                                     header.version, &callbacks, &settings, &params, NULL, s);
    if (rv != 0) return -1;

    nghttp3_callbacks h3_callbacks;
    memset(&h3_callbacks, 0, sizeof(h3_callbacks));
    h3_callbacks.begin_headers = h3_begin_headers_cb;
    h3_callbacks.recv_header = h3_recv_header_cb;
    h3_callbacks.end_headers = h3_end_headers_cb;
    h3_callbacks.recv_data = h3_recv_data_cb;
    h3_callbacks.end_stream = h3_end_stream_cb;
    h3_callbacks.deferred_consume = h3_deferred_consume_cb;
    h3_callbacks.stop_sending = h3_stop_sending_cb;
    nghttp3_settings h3_settings;
    nghttp3_settings_default(&h3_settings);
    h3_settings.max_field_section_size = s->max_header_bytes;
    h3_settings.qpack_max_dtable_capacity = 4096;
    h3_settings.qpack_blocked_streams = 100;
    rv = nghttp3_conn_server_new(&s->http3_conn, &h3_callbacks, &h3_settings,
                                 nghttp3_mem_default(), s);
    if (rv != 0) return -1;
    nghttp3_conn_set_max_client_streams_bidi(s->http3_conn, params.initial_max_streams_bidi);

    if (!ssl_ctx) return -1;
    s->ssl = SSL_new(ssl_ctx);
    if (!s->ssl) return -1;
    SSL_set_app_data(s->ssl, &s->conn_ref);
    SSL_set_accept_state(s->ssl);
    SSL_set_quic_tls_early_data_enabled(s->ssl, 0);
    if (ngtcp2_crypto_ossl_configure_server_session(s->ssl) != 0 ||
        ngtcp2_crypto_ossl_ctx_new(&s->ossl_ctx, s->ssl) != 0) return -1;
    ngtcp2_conn_set_tls_native_handle(s->quic_conn, s->ossl_ctx);

    memcpy(&s->peer_addr, peer, peer_len);
    s->peer_addrlen = peer_len;
    s->peer_set = 1;
    return 0;
}

const char *ziserver_nghttp3_version_text(void) {
    return "ngtcp2/" NGTCP2_VERSION " nghttp3/" NGHTTP3_VERSION;
}

int ziserver_nghttp3_serve(
    void *userdata,
    ziserver_quic_read_fn read_fn,
    ziserver_quic_write_fn write_fn,
    ziserver_h3_dispatch_fn dispatch_fn,
    ziserver_h3_release_fn release_fn,
    ziserver_stop_fn stop_fn,
    ziserver_now_fn now_fn,
    void *ssl_ctx_ptr,
    size_t max_header_bytes,
    size_t max_body_bytes,
    size_t max_requests,
    ziserver_quic_summary *summary
) {
    quic_session *s = (quic_session *)calloc(1, sizeof(*s));
    if (!s) return -1;
    s->userdata = userdata;
    s->read_fn = read_fn;
    s->write_fn = write_fn;
    s->dispatch_fn = dispatch_fn;
    s->release_fn = release_fn;
    s->stop_fn = stop_fn;
    s->now_fn = now_fn;
    s->max_header_bytes = max_header_bytes;
    s->max_body_bytes = max_body_bytes;
    s->max_requests = max_requests ? max_requests : SIZE_MAX;
    s->conn_ref.get_conn = get_conn_cb;
    s->conn_ref.user_data = s;

    int result = 0;
    while (!s->closing && !s->stop_fn(s->userdata)) {
        uint8_t packet[65536];
        struct sockaddr_storage peer;
        size_t peer_len = sizeof(peer);
        int nread = s->read_fn(s->userdata, packet, sizeof(packet), &peer, &peer_len,
                               next_read_timeout_ms(s));
        uint64_t now = s->now_fn(s->userdata);
        if (nread < 0) {
            if (s->stop_fn(s->userdata)) break;
            result = -3;
            break;
        }
        if (nread == 0) {
            if (s->quic_conn && ngtcp2_conn_get_expiry2(s->quic_conn) <= now) {
                int rv = ngtcp2_conn_handle_expiry(s->quic_conn, now);
                if (rv == NGTCP2_ERR_IDLE_CLOSE || rv == NGTCP2_ERR_HANDSHAKE_TIMEOUT) break;
                if (rv != 0) { result = -4; break; }
                if (flush_packets(s) != 0) { result = -6; break; }
            }
            continue;
        }
        if (s->peer_set && !sockaddr_equal(&s->peer_addr, s->peer_addrlen, &peer, peer_len))
            continue;
        if (!s->quic_conn) {
            int init = initialize_connection(s, packet, (size_t)nread, &peer, peer_len,
                                             (SSL_CTX *)ssl_ctx_ptr, now);
            if (init > 0) continue;
            if (init < 0) { result = -2; break; }
        }
        ngtcp2_pkt_info pi;
        memset(&pi, 0, sizeof(pi));
        int rv = ngtcp2_conn_read_pkt(s->quic_conn, &s->path.path, &pi,
                                      packet, (size_t)nread, now);
        if (rv == NGTCP2_ERR_DRAINING || rv == NGTCP2_ERR_DROP_CONN || rv == NGTCP2_ERR_RETRY) break;
        if (rv != 0) { result = -5; break; }
        if (s->request_count >= s->max_requests && !s->summary.goaway_sent) {
            if (nghttp3_conn_submit_shutdown_notice(s->http3_conn) == 0) s->summary.goaway_sent = 1;
        }
        if (flush_packets(s) != 0) { result = -6; break; }
    }

    if (summary) *summary = s->summary;
    free_all_streams(s);
    if (s->http3_conn) nghttp3_conn_del(s->http3_conn);
    if (s->ssl) {
        SSL_free(s->ssl);
    }
    if (s->ossl_ctx) ngtcp2_crypto_ossl_ctx_del(s->ossl_ctx);
    if (s->quic_conn) ngtcp2_conn_del(s->quic_conn);
    free(s);
    return result;
}

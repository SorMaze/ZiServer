#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <nghttp2/nghttp2.h>

#define ZISERVER_H2_MAX_HEADERS 64
#define ZISERVER_H2_MAX_RESPONSE_HEADERS 24
#define ZISERVER_H2_MAX_CONCURRENT_STREAMS 128
#define ZISERVER_H2_HEADER_ENTRY_OVERHEAD 32
// Give a just-finished Zig handler a chance to publish into the internal ready
// queue before falling back to the socket event wait. This is especially
// important on Windows, where a 1 ms wait may be rounded to a full scheduler
// tick even though no socket activity is needed to produce the response.
#define ZISERVER_H2_RESPONSE_POLL_SPINS 1024

typedef struct {
    const uint8_t *name_ptr;
    size_t name_len;
    const uint8_t *value_ptr;
    size_t value_len;
} ziserver_h2_header;

/* Memory ownership helpers implemented in Zig with std.heap.c_allocator. */
extern uint8_t *ziserver_h2_copy_zig(const uint8_t *value_ptr, size_t len);
extern void ziserver_h2_free_zig(uint8_t *value_ptr, size_t len);
extern int ziserver_h2_replace_zig(
    uint8_t **destination_ptr,
    size_t *destination_len,
    const uint8_t *value_ptr,
    size_t len
);
extern int ziserver_h2_append_body_zig(
    uint8_t **body_ptr,
    size_t *body_len,
    size_t *body_capacity,
    const uint8_t *data_ptr,
    size_t data_len,
    size_t max_body_bytes
);
extern void ziserver_h2_stream_fields_free_zig(
    uint8_t *method,
    size_t method_len,
    uint8_t *path,
    size_t path_len,
    uint8_t *authority,
    size_t authority_len,
    const ziserver_h2_header *headers_ptr,
    size_t headers_len,
    uint8_t *body,
    size_t body_capacity,
    uint8_t *response_body,
    size_t response_body_len
);

typedef struct {
    const uint8_t *method_ptr;
    size_t method_len;
    const uint8_t *path_ptr;
    size_t path_len;
    const uint8_t *authority_ptr;
    size_t authority_len;
    const ziserver_h2_header *headers_ptr;
    size_t headers_len;
    const uint8_t *body_ptr;
    size_t body_len;
    uint16_t error_status;
} ziserver_h2_request;

typedef struct {
    uint16_t status;
    const uint8_t *content_type_ptr;
    size_t content_type_len;
    size_t content_length;
    uint8_t *body_ptr;
    size_t body_len;
    const uint8_t *cache_ptr;
    size_t cache_len;
    ziserver_h2_header headers[ZISERVER_H2_MAX_RESPONSE_HEADERS];
    size_t headers_len;
    uint8_t streaming;
    uint8_t content_length_known;
} ziserver_h2_response;

typedef intptr_t (*ziserver_h2_read_fn)(void *userdata, uint8_t *buffer, size_t len, int active_streams, int pending_dispatches);
typedef int (*ziserver_h2_read_ready_fn)(void *userdata, uint32_t timeout_ms);
typedef int (*ziserver_h2_yield_fn)(void *userdata);
typedef int (*ziserver_h2_write_fn)(void *userdata, const uint8_t *buffer, size_t len);
typedef int (*ziserver_h2_shutdown_fn)(void *userdata);
typedef int (*ziserver_h2_dispatch_start_fn)(
    void *userdata,
    const ziserver_h2_request *request,
    void **task_out
);
typedef int (*ziserver_h2_dispatch_poll_fn)(void *userdata, void *task, ziserver_h2_response *response);
typedef void (*ziserver_h2_dispatch_cancel_fn)(void *userdata, void *task);
typedef void *(*ziserver_h2_dispatch_take_ready_fn)(void *userdata);
typedef void (*ziserver_h2_release_fn)(void *userdata, ziserver_h2_response *response);
typedef int (*ziserver_h2_dispatch_data_fn)(void *userdata, void *task, const uint8_t *data, size_t len, int end_stream);
typedef intptr_t (*ziserver_h2_response_read_fn)(void *userdata, void *task, uint8_t *buffer, size_t len, int *end_out);
typedef int (*ziserver_h2_response_ready_fn)(void *userdata, void *task);

typedef struct ziserver_h2_session ziserver_h2_session;

typedef struct ziserver_h2_stream {
    int32_t stream_id;
    uint8_t *method;
    size_t method_len;
    uint8_t *path;
    size_t path_len;
    uint8_t *authority;
    size_t authority_len;
    ziserver_h2_header headers[ZISERVER_H2_MAX_HEADERS];
    size_t headers_len;
    size_t header_bytes;
    uint8_t *body;
    size_t body_len;
    size_t body_capacity;
    uint8_t *response_body;
    size_t response_body_len;
    size_t response_body_offset;
    int responded;
    int streaming_response;
    int dispatch_completed;
    int request_ended;
    ziserver_h2_session *context;
    void *dispatch_task;
    int dispatch_started;
    int method_seen;
    int path_seen;
    int authority_seen;
    uint16_t request_error_status;
    struct ziserver_h2_stream *next;
} ziserver_h2_stream;

typedef struct {
    uint64_t requests;
    uint32_t highest_stream_id;
    uint8_t goaway_sent;
} ziserver_h2_summary;

struct ziserver_h2_session {
    void *userdata;
    ziserver_h2_read_fn read;
    ziserver_h2_read_ready_fn read_ready;
    ziserver_h2_yield_fn yield;
    ziserver_h2_write_fn write;
    ziserver_h2_shutdown_fn should_shutdown;
    ziserver_h2_dispatch_start_fn dispatch_start;
    ziserver_h2_dispatch_poll_fn dispatch_poll;
    ziserver_h2_dispatch_cancel_fn dispatch_cancel;
    ziserver_h2_dispatch_take_ready_fn dispatch_take_ready;
    ziserver_h2_release_fn release;
    ziserver_h2_dispatch_data_fn dispatch_data;
    ziserver_h2_response_read_fn response_read;
    ziserver_h2_response_ready_fn response_ready;
    size_t max_header_bytes;
    size_t max_body_bytes;
    size_t max_requests;
    uint64_t request_count;
    uint32_t highest_stream_id;
    size_t active_streams;
    size_t pending_dispatches;
    int goaway_sent;
    ziserver_h2_stream *streams;
};

static void ziserver_h2_stream_free(ziserver_h2_stream *stream) {
    if (stream == NULL) {
        return;
    }
    ziserver_h2_stream_fields_free_zig(
        stream->method,
        stream->method_len,
        stream->path,
        stream->path_len,
        stream->authority,
        stream->authority_len,
        stream->headers,
        stream->headers_len,
        stream->body,
        stream->body_capacity,
        stream->response_body,
        stream->response_body_len
    );
    free(stream);
}

static void ziserver_h2_cancel_stream_dispatch(
    ziserver_h2_session *context,
    ziserver_h2_stream *stream
) {
    if (stream->dispatch_task != NULL) {
        context->dispatch_cancel(context->userdata, stream->dispatch_task);
        stream->dispatch_task = NULL;
        if (context->pending_dispatches != 0) {
            context->pending_dispatches -= 1;
        }
    }
}

static void ziserver_h2_unlink_stream(
    ziserver_h2_session *context,
    ziserver_h2_stream *stream
) {
    ziserver_h2_stream **cursor = &context->streams;
    while (*cursor != NULL) {
        if (*cursor == stream) {
            *cursor = stream->next;
            return;
        }
        cursor = &(*cursor)->next;
    }
}

static ssize_t ziserver_h2_send_callback(
    nghttp2_session *session,
    const uint8_t *data,
    size_t length,
    int flags,
    void *user_data
) {
    (void)session;
    (void)flags;
    ziserver_h2_session *context = user_data;
    if (context->write(context->userdata, data, length) != 0) {
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return (ssize_t)length;
}

static int ziserver_h2_on_begin_headers(
    nghttp2_session *session,
    const nghttp2_frame *frame,
    void *user_data
) {
    ziserver_h2_session *context = user_data;
    if (frame->hd.type != NGHTTP2_HEADERS || frame->headers.cat != NGHTTP2_HCAT_REQUEST) {
        return 0;
    }

    ziserver_h2_stream *stream = calloc(1, sizeof(*stream));
    if (stream == NULL) {
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    stream->stream_id = frame->hd.stream_id;
    stream->context = context;
    stream->next = context->streams;
    context->streams = stream;
    context->active_streams += 1;
    if ((uint32_t)stream->stream_id > context->highest_stream_id) {
        context->highest_stream_id = (uint32_t)stream->stream_id;
    }
    if (nghttp2_session_set_stream_user_data(session, stream->stream_id, stream) != 0) {
        ziserver_h2_unlink_stream(context, stream);
        context->active_streams -= 1;
        ziserver_h2_stream_free(stream);
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

static int ziserver_h2_on_header(
    nghttp2_session *session,
    const nghttp2_frame *frame,
    const uint8_t *name,
    size_t name_len,
    const uint8_t *value,
    size_t value_len,
    uint8_t flags,
    void *user_data
) {
    (void)flags;
    ziserver_h2_session *context = user_data;
    if (frame->hd.type != NGHTTP2_HEADERS || frame->headers.cat != NGHTTP2_HCAT_REQUEST) {
        return 0;
    }

    ziserver_h2_stream *stream = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    if (stream == NULL) {
        return 0;
    }
    if (name_len > context->max_header_bytes ||
        value_len > context->max_header_bytes - name_len ||
        ZISERVER_H2_HEADER_ENTRY_OVERHEAD > context->max_header_bytes - name_len - value_len ||
        stream->header_bytes > context->max_header_bytes - name_len - value_len - ZISERVER_H2_HEADER_ENTRY_OVERHEAD) {
        stream->request_error_status = 431;
        return 0;
    }
    stream->header_bytes += name_len + value_len + ZISERVER_H2_HEADER_ENTRY_OVERHEAD;
    if (stream->request_error_status != 0) {
        return 0;
    }
    if (name_len != 0 && name[0] == ':') {
        if (name_len == 7 && memcmp(name, ":method", 7) == 0) {
            if (stream->method_seen) {
                stream->request_error_status = 400;
                return 0;
            }
            stream->method_seen = 1;
            return ziserver_h2_replace_zig(&stream->method, &stream->method_len, value, value_len) == 0
                ? 0
                : NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        if (name_len == 5 && memcmp(name, ":path", 5) == 0) {
            if (stream->path_seen) {
                stream->request_error_status = 400;
                return 0;
            }
            stream->path_seen = 1;
            return ziserver_h2_replace_zig(&stream->path, &stream->path_len, value, value_len) == 0
                ? 0
                : NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        if (name_len == 10 && memcmp(name, ":authority", 10) == 0) {
            if (stream->authority_seen) {
                stream->request_error_status = 400;
                return 0;
            }
            stream->authority_seen = 1;
            return ziserver_h2_replace_zig(&stream->authority, &stream->authority_len, value, value_len) == 0
                ? 0
                : NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        return 0;
    }

    if (stream->headers_len >= ZISERVER_H2_MAX_HEADERS) {
        stream->request_error_status = 431;
        return 0;
    }
    uint8_t *name_copy = ziserver_h2_copy_zig(name, name_len);
    uint8_t *value_copy = ziserver_h2_copy_zig(value, value_len);
    if ((name_len != 0 && name_copy == NULL) || (value_len != 0 && value_copy == NULL)) {
        ziserver_h2_free_zig(name_copy, name_len);
        ziserver_h2_free_zig(value_copy, value_len);
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    stream->headers[stream->headers_len++] = (ziserver_h2_header){
        name_copy,
        name_len,
        value_copy,
        value_len,
    };
    return 0;
}

static int ziserver_h2_on_data_chunk(
    nghttp2_session *session,
    uint8_t flags,
    int32_t stream_id,
    const uint8_t *data,
    size_t len,
    void *user_data
) {
    (void)flags;
    ziserver_h2_session *context = user_data;
    ziserver_h2_stream *stream = nghttp2_session_get_stream_user_data(session, stream_id);
    if (stream == NULL) {
        return 0;
    }
    if (stream->request_error_status != 0) {
        return 0;
    }
    if (len > context->max_body_bytes || stream->body_len > context->max_body_bytes - len) {
        stream->request_error_status = 413;
        if (stream->dispatch_task != NULL) {
            context->dispatch_data(context->userdata, stream->dispatch_task, NULL, 0, -1);
        }
        return nghttp2_submit_rst_stream(
            session,
            NGHTTP2_FLAG_NONE,
            stream_id,
            NGHTTP2_ENHANCE_YOUR_CALM
        );
    }
    if (stream->dispatch_task != NULL) {
        stream->body_len += len;
        return context->dispatch_data(context->userdata, stream->dispatch_task, data, len, 0) == 0
            ? 0
            : NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    int append_result = ziserver_h2_append_body_zig(
        &stream->body,
        &stream->body_len,
        &stream->body_capacity,
        data,
        len,
        context->max_body_bytes
    );
    if (append_result == 1) {
        stream->request_error_status = 413;
        return 0;
    }
    return append_result == 0 ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
}

static nghttp2_ssize ziserver_h2_read_response(
    nghttp2_session *session,
    int32_t stream_id,
    uint8_t *buffer,
    size_t length,
    uint32_t *data_flags,
    nghttp2_data_source *source,
    void *user_data
) {
    (void)session;
    (void)stream_id;
    (void)user_data;
    ziserver_h2_stream *stream = source->ptr;
    if (stream->streaming_response) {
        int end_stream = 0;
        intptr_t result = stream->context->response_read(
            stream->context->userdata,
            stream->dispatch_task,
            buffer,
            length,
            &end_stream
        );
        if (end_stream != 0) *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        if (result > 0) return (nghttp2_ssize)result;
        if (result == 0) {
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
            return 0;
        }
        if (result == -2) return NGHTTP2_ERR_DEFERRED;
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    size_t remaining = stream->response_body_len - stream->response_body_offset;
    size_t amount = remaining < length ? remaining : length;
    if (amount != 0) {
        memcpy(buffer, stream->response_body + stream->response_body_offset, amount);
        stream->response_body_offset += amount;
    }
    if (stream->response_body_offset == stream->response_body_len) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;
    }
    return (nghttp2_ssize)amount;
}

static nghttp2_nv ziserver_h2_nv(
    const uint8_t *name,
    size_t name_len,
    const uint8_t *value,
    size_t value_len
) {
    return (nghttp2_nv){
        (uint8_t *)name,
        (uint8_t *)value,
        name_len,
        value_len,
        NGHTTP2_NV_FLAG_NONE,
    };
}

static int ziserver_h2_submit_response(
    nghttp2_session *session,
    ziserver_h2_session *context,
    ziserver_h2_stream *stream,
    ziserver_h2_response *captured_response,
    int dispatch_result
) {
    ziserver_h2_response response = *captured_response;
    int response_released = 0;
    if (dispatch_result != 0 || response.content_type_ptr == NULL) {
        static const uint8_t fallback_type[] = "text/plain; charset=utf-8";
        static const uint8_t fallback_body[] = "internal server error\n";
        context->release(context->userdata, &response);
        response_released = 1;
        response.status = 500;
        response.content_type_ptr = fallback_type;
        response.content_type_len = sizeof(fallback_type) - 1;
        response.content_length = sizeof(fallback_body) - 1;
        response.content_length_known = 1;
        response.body_ptr = (uint8_t *)fallback_body;
        response.body_len = sizeof(fallback_body) - 1;
        response.cache_ptr = NULL;
        response.cache_len = 0;
        static const uint8_t nosniff_name[] = "x-content-type-options";
        static const uint8_t nosniff_value[] = "nosniff";
        static const uint8_t frame_name[] = "x-frame-options";
        static const uint8_t frame_value[] = "DENY";
        static const uint8_t referrer_name[] = "referrer-policy";
        static const uint8_t referrer_value[] = "no-referrer";
        static const uint8_t permissions_name[] = "permissions-policy";
        static const uint8_t permissions_value[] = "camera=(), microphone=(), geolocation=()";
        response.headers[0] = (ziserver_h2_header){nosniff_name, sizeof(nosniff_name) - 1, nosniff_value, sizeof(nosniff_value) - 1};
        response.headers[1] = (ziserver_h2_header){frame_name, sizeof(frame_name) - 1, frame_value, sizeof(frame_value) - 1};
        response.headers[2] = (ziserver_h2_header){referrer_name, sizeof(referrer_name) - 1, referrer_value, sizeof(referrer_value) - 1};
        response.headers[3] = (ziserver_h2_header){permissions_name, sizeof(permissions_name) - 1, permissions_value, sizeof(permissions_value) - 1};
        response.headers_len = 4;
    }

    if (response.body_len != 0) {
        if (!response_released) {
            stream->response_body = response.body_ptr;
            stream->response_body_len = response.body_len;
            response.body_ptr = NULL;
            response.body_len = 0;
        } else {
            stream->response_body = ziserver_h2_copy_zig(response.body_ptr, response.body_len);
            if (stream->response_body == NULL) {
                return NGHTTP2_ERR_NOMEM;
            }
            stream->response_body_len = response.body_len;
        }
    }
    stream->streaming_response = response.streaming != 0;

    char status_buffer[4];
    int status_len = snprintf(status_buffer, sizeof(status_buffer), "%u", response.status);
    char content_length_buffer[32];
    int content_length_len = snprintf(
        content_length_buffer,
        sizeof(content_length_buffer),
        "%zu",
        response.content_length
    );
    static const uint8_t status_name[] = ":status";
    static const uint8_t content_type_name[] = "content-type";
    static const uint8_t content_length_name[] = "content-length";
    static const uint8_t cache_control_name[] = "cache-control";

    nghttp2_nv headers[6 + ZISERVER_H2_MAX_RESPONSE_HEADERS];
    size_t header_count = 0;
    headers[header_count++] = ziserver_h2_nv(status_name, sizeof(status_name) - 1, (uint8_t *)status_buffer, (size_t)status_len);
    headers[header_count++] = ziserver_h2_nv(content_type_name, sizeof(content_type_name) - 1, response.content_type_ptr, response.content_type_len);
    if (response.content_length_known != 0) {
        headers[header_count++] = ziserver_h2_nv(content_length_name, sizeof(content_length_name) - 1, (uint8_t *)content_length_buffer, (size_t)content_length_len);
    }
    if (response.cache_ptr != NULL && response.cache_len != 0) {
        headers[header_count++] = ziserver_h2_nv(cache_control_name, sizeof(cache_control_name) - 1, response.cache_ptr, response.cache_len);
    }
    size_t extra_header_count = response.headers_len;
    if (extra_header_count > ZISERVER_H2_MAX_RESPONSE_HEADERS) {
        extra_header_count = ZISERVER_H2_MAX_RESPONSE_HEADERS;
    }
    for (size_t i = 0; i < extra_header_count; ++i) {
        headers[header_count++] = ziserver_h2_nv(
            response.headers[i].name_ptr,
            response.headers[i].name_len,
            response.headers[i].value_ptr,
            response.headers[i].value_len
        );
    }

    nghttp2_data_provider2 provider;
    nghttp2_data_provider2 *provider_ptr = NULL;
    if (stream->streaming_response || stream->response_body_len != 0) {
        provider.source.ptr = stream;
        provider.read_callback = ziserver_h2_read_response;
        provider_ptr = &provider;
    }
    int result = nghttp2_submit_response2(
        session,
        stream->stream_id,
        headers,
        header_count,
        provider_ptr
    );
    if (!response_released) {
        context->release(context->userdata, &response);
    }
    stream->responded = result == 0;
    return result;
}

static int ziserver_h2_on_frame_recv(
    nghttp2_session *session,
    const nghttp2_frame *frame,
    void *user_data
) {
    if (frame->hd.type != NGHTTP2_HEADERS && frame->hd.type != NGHTTP2_DATA) return 0;
    ziserver_h2_stream *stream = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    if (stream == NULL) return 0;
    ziserver_h2_session *context = user_data;
    if (frame->hd.type == NGHTTP2_HEADERS && !stream->dispatch_started) {
        if (stream->method == NULL || stream->path == NULL) stream->request_error_status = 400;
        ziserver_h2_request request = {
            stream->method, stream->method_len,
            stream->path, stream->path_len,
            stream->authority, stream->authority_len,
            stream->headers, stream->headers_len,
            NULL, 0,
            stream->request_error_status,
        };
        stream->dispatch_started = 1;
        if (context->dispatch_start(context->userdata, &request, &stream->dispatch_task) != 0 ||
            stream->dispatch_task == NULL) {
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        context->pending_dispatches += 1;
    }
    if ((frame->hd.flags & NGHTTP2_FLAG_END_STREAM) != 0 && stream->dispatch_task != NULL) {
        stream->request_ended = 1;
        if (context->dispatch_data(context->userdata, stream->dispatch_task, NULL, 0, 1) != 0) {
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    return 0;
}

/// A handler with a request body cannot make progress until the peer's next
/// DATA frame arrives. Do not route that case through the short response-poll
/// timeout: on Windows a nominal 1 ms event wait is commonly rounded to the
/// scheduler quantum, turning a normal HEADERS -> DATA sequence into a large
/// per-request delay and starving concurrent POST streams.
static int ziserver_h2_has_open_request_body(const ziserver_h2_session *context) {
    for (const ziserver_h2_stream *stream = context->streams; stream != NULL; stream = stream->next) {
        if (stream->dispatch_task != NULL && !stream->request_ended) return 1;
    }
    return 0;
}

static int ziserver_h2_poll_dispatch(
    nghttp2_session *session,
    ziserver_h2_session *context,
    ziserver_h2_stream *stream
) {
    if (stream->dispatch_task == NULL) return 0;
    ziserver_h2_response response;
    memset(&response, 0, sizeof(response));
    response.status = 500;
    int poll_result = context->dispatch_poll(
        context->userdata,
        stream->dispatch_task,
        &response
    );
    if (poll_result < 0 && !stream->responded) {
        int submit_result = ziserver_h2_submit_response(session, context, stream, &response, -1);
        if (submit_result != 0) return submit_result;
    } else if ((poll_result == 1 || poll_result == 2) && !stream->responded) {
        int submit_result = ziserver_h2_submit_response(session, context, stream, &response, 0);
        if (submit_result != 0) return submit_result;
        context->request_count += 1;
    } else if (poll_result == 3 && !stream->dispatch_completed) {
        stream->dispatch_completed = 1;
    }
    if (stream->responded && stream->streaming_response &&
        context->response_ready(context->userdata, stream->dispatch_task) != 0) {
        int resume_result = nghttp2_session_resume_data(session, stream->stream_id);
        if (resume_result != 0 && resume_result != NGHTTP2_ERR_INVALID_ARGUMENT) return resume_result;
    }
    return 0;
}

static ziserver_h2_stream *ziserver_h2_find_dispatch_stream(
    ziserver_h2_session *context,
    void *task
) {
    for (ziserver_h2_stream *stream = context->streams; stream != NULL; stream = stream->next) {
        if (stream->dispatch_task == task) return stream;
    }
    return NULL;
}

static int ziserver_h2_poll_ready_dispatches(
    nghttp2_session *session,
    ziserver_h2_session *context
) {
    while (1) {
        void *task = context->dispatch_take_ready(context->userdata);
        if (task == NULL) return 0;
        ziserver_h2_stream *stream = ziserver_h2_find_dispatch_stream(context, task);
        if (stream == NULL) continue;
        int result = ziserver_h2_poll_dispatch(session, context, stream);
        if (result != 0) return result;
    }
}

static int ziserver_h2_on_stream_close(
    nghttp2_session *session,
    int32_t stream_id,
    uint32_t error_code,
    void *user_data
) {
    (void)error_code;
    ziserver_h2_session *context = user_data;
    ziserver_h2_stream *stream = nghttp2_session_get_stream_user_data(session, stream_id);
    if (stream != NULL) {
        ziserver_h2_cancel_stream_dispatch(context, stream);
        nghttp2_session_set_stream_user_data(session, stream_id, NULL);
        ziserver_h2_unlink_stream(context, stream);
        if (context->active_streams != 0) {
            context->active_streams -= 1;
        }
        ziserver_h2_stream_free(stream);
    }
    return 0;
}

const char *ziserver_nghttp2_version_text(void) {
    const nghttp2_info *info = nghttp2_version(0);
    return info == NULL ? "unknown" : info->version_str;
}

const char *ziserver_nghttp2_error_text(int error_code) {
    return nghttp2_strerror(error_code);
}

int ziserver_nghttp2_serve(
    void *userdata,
    ziserver_h2_read_fn read_fn,
    ziserver_h2_read_ready_fn read_ready_fn,
    ziserver_h2_yield_fn yield_fn,
    ziserver_h2_write_fn write_fn,
    ziserver_h2_shutdown_fn shutdown_fn,
    ziserver_h2_dispatch_start_fn dispatch_start_fn,
    ziserver_h2_dispatch_poll_fn dispatch_poll_fn,
    ziserver_h2_dispatch_cancel_fn dispatch_cancel_fn,
    ziserver_h2_dispatch_take_ready_fn dispatch_take_ready_fn,
    ziserver_h2_release_fn release_fn,
    ziserver_h2_dispatch_data_fn dispatch_data_fn,
    ziserver_h2_response_read_fn response_read_fn,
    ziserver_h2_response_ready_fn response_ready_fn,
    size_t max_header_bytes,
    size_t max_body_bytes,
    size_t max_requests,
    ziserver_h2_summary *summary
) {
    ziserver_h2_session context = {
        .userdata = userdata,
        .read = read_fn,
        .read_ready = read_ready_fn,
        .yield = yield_fn,
        .write = write_fn,
        .should_shutdown = shutdown_fn,
        .dispatch_start = dispatch_start_fn,
        .dispatch_poll = dispatch_poll_fn,
        .dispatch_cancel = dispatch_cancel_fn,
        .dispatch_take_ready = dispatch_take_ready_fn,
        .release = release_fn,
        .dispatch_data = dispatch_data_fn,
        .response_read = response_read_fn,
        .response_ready = response_ready_fn,
        .max_header_bytes = max_header_bytes,
        .max_body_bytes = max_body_bytes,
        .max_requests = max_requests == 0 ? 1 : max_requests,
    };
    nghttp2_session_callbacks *callbacks = NULL;
    nghttp2_session *session = NULL;

    int result = nghttp2_session_callbacks_new(&callbacks);
    if (result != 0) {
        return result;
    }
    nghttp2_session_callbacks_set_send_callback(callbacks, ziserver_h2_send_callback);
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, ziserver_h2_on_begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, ziserver_h2_on_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, ziserver_h2_on_data_chunk);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, ziserver_h2_on_frame_recv);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, ziserver_h2_on_stream_close);

    result = nghttp2_session_server_new(&session, callbacks, &context);
    nghttp2_session_callbacks_del(callbacks);
    if (result != 0) {
        return result;
    }

    uint64_t receive_window_wide = (uint64_t)max_body_bytes + 16384u;
    if (receive_window_wide > 262144u) receive_window_wide = 262144u;
    uint32_t receive_window = receive_window_wide > 0x7fffffffu
        ? 0x7fffffffu
        : (uint32_t)receive_window_wide;
    nghttp2_settings_entry settings[] = {
        {NGHTTP2_SETTINGS_HEADER_TABLE_SIZE, 4096},
        {NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, ZISERVER_H2_MAX_CONCURRENT_STREAMS},
        {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, receive_window},
        {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, (uint32_t)max_header_bytes},
    };
    result = nghttp2_submit_settings(
        session,
        NGHTTP2_FLAG_NONE,
        settings,
        sizeof(settings) / sizeof(settings[0])
    );
    if (result == 0) {
        result = nghttp2_session_send(session);
    }

    uint8_t input[16384];
    size_t goaway_request_limit = context.max_requests <= 1
        ? context.max_requests
        : (context.max_requests > SIZE_MAX - ZISERVER_H2_MAX_CONCURRENT_STREAMS
            ? SIZE_MAX
            : context.max_requests + ZISERVER_H2_MAX_CONCURRENT_STREAMS);
    size_t response_poll_spins = 0;
    while (result == 0 && (nghttp2_session_want_read(session) || nghttp2_session_want_write(session))) {
        result = ziserver_h2_poll_ready_dispatches(session, &context);
        if (result == 0) result = nghttp2_session_send(session);
        if (result == 0 && !context.goaway_sent &&
            context.request_count >= goaway_request_limit &&
            context.pending_dispatches == 0) {
            result = nghttp2_submit_goaway(
                session,
                NGHTTP2_FLAG_NONE,
                (int32_t)context.highest_stream_id,
                NGHTTP2_NO_ERROR,
                NULL,
                0
            );
            if (result == 0) {
                context.goaway_sent = 1;
                result = nghttp2_session_send(session);
            }
        }
        if (context.should_shutdown(context.userdata) != 0 && !context.goaway_sent) {
            result = nghttp2_submit_goaway(
                session,
                NGHTTP2_FLAG_NONE,
                (int32_t)context.highest_stream_id,
                NGHTTP2_NO_ERROR,
                NULL,
                0
            );
            if (result != 0) {
                break;
            }
            context.goaway_sent = 1;
            result = nghttp2_session_send(session);
        }
        if (result != 0) {
            break;
        }

        if (context.pending_dispatches != 0 && !ziserver_h2_has_open_request_body(&context)) {
            if (response_poll_spins < ZISERVER_H2_RESPONSE_POLL_SPINS) {
                response_poll_spins += 1;
                if (context.yield(context.userdata) != 0) {
                    result = NGHTTP2_ERR_CALLBACK_FAILURE;
                    break;
                }
                continue;
            }
            response_poll_spins = 0;
            // Dispatch tasks can finish while the socket is idle. Keep this
            // bounded wait as a slow-handler fallback, but let immediate
            // ready-queue responses avoid the platform timer quantum above.
            int ready = context.read_ready(context.userdata, 1);
            if (ready == 0) continue;
            if (ready < 0) {
                result = NGHTTP2_ERR_CALLBACK_FAILURE;
                break;
            }
        }
        response_poll_spins = 0;
        intptr_t read_result = context.read(
            context.userdata,
            input,
            sizeof(input),
            context.active_streams != 0,
            context.pending_dispatches != 0
        );
        if (read_result == 0) {
            break;
        }
        if (read_result == -2 || read_result == -3) {
            if (!context.goaway_sent) {
                result = nghttp2_submit_goaway(
                    session,
                    NGHTTP2_FLAG_NONE,
                    (int32_t)context.highest_stream_id,
                    read_result == -3 || context.active_streams == 0
                        ? NGHTTP2_NO_ERROR
                        : NGHTTP2_ENHANCE_YOUR_CALM,
                    NULL,
                    0
                );
                if (result == 0) {
                    context.goaway_sent = 1;
                    result = nghttp2_session_send(session);
                }
            }
            break;
        }
        if (read_result < 0) {
            result = NGHTTP2_ERR_CALLBACK_FAILURE;
            break;
        }
        nghttp2_ssize consumed = nghttp2_session_mem_recv2(session, input, (size_t)read_result);
        if (consumed < 0 || consumed != read_result) {
            result = consumed < 0 ? (int)consumed : NGHTTP2_ERR_PROTO;
            break;
        }
        result = nghttp2_session_send(session);
    }

    nghttp2_session_del(session);
    while (context.streams != NULL) {
        ziserver_h2_stream *stream = context.streams;
        context.streams = stream->next;
        ziserver_h2_cancel_stream_dispatch(&context, stream);
        ziserver_h2_stream_free(stream);
    }
    if (summary != NULL) {
        summary->requests = context.request_count;
        summary->highest_stream_id = context.highest_stream_id;
        summary->goaway_sent = context.goaway_sent ? 1 : 0;
    }
    return result;
}

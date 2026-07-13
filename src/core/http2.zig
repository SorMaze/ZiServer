const std = @import("std");
const build_options = @import("build_options");

const http_config = @import("http_config.zig");
const logger = @import("log.zig");
const errors = @import("errors.zig");
const response = @import("response.zig");
const streaming = @import("streaming.zig");
const transport = @import("transport.zig");

pub const linked = std.mem.eql(u8, build_options.http2_provider, "nghttp2");
pub const capture_allocator = if (linked) std.heap.c_allocator else std.heap.page_allocator;
const http2_helpers = if (linked) @import("http2_helpers.zig") else struct {};

comptime {
    if (linked) {
        _ = http2_helpers.ziserver_h2_copy_zig;
        _ = http2_helpers.ziserver_h2_free_zig;
        _ = http2_helpers.ziserver_h2_replace_zig;
        _ = http2_helpers.ziserver_h2_append_body_zig;
        _ = http2_helpers.ziserver_h2_stream_fields_free_zig;
    }
}

pub const Support = enum {
    disabled,
    reject_preface,
    adapter,
};

pub const Request = extern struct {
    method_ptr: ?[*]const u8,
    method_len: usize,
    path_ptr: ?[*]const u8,
    path_len: usize,
    authority_ptr: ?[*]const u8,
    authority_len: usize,
    headers_ptr: ?[*]const response.CapturedHeader,
    headers_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
    error_status: u16,

    pub fn method(self: *const Request) []const u8 {
        const ptr = self.method_ptr orelse return &.{};
        return ptr[0..self.method_len];
    }

    pub fn path(self: *const Request) []const u8 {
        const ptr = self.path_ptr orelse return &.{};
        return ptr[0..self.path_len];
    }

    pub fn authority(self: *const Request) []const u8 {
        const ptr = self.authority_ptr orelse return &.{};
        return ptr[0..self.authority_len];
    }

    pub fn headers(self: *const Request) []const response.CapturedHeader {
        const ptr = self.headers_ptr orelse return &.{};
        return ptr[0..self.headers_len];
    }

    pub fn body(self: *const Request) []const u8 {
        const ptr = self.body_ptr orelse return &.{};
        return ptr[0..self.body_len];
    }
};

pub const Summary = extern struct {
    requests: u64 = 0,
    highest_stream_id: u32 = 0,
    goaway_sent: u8 = 0,

    pub fn sentGoaway(self: Summary) bool {
        return self.goaway_sent != 0;
    }
};

pub const DispatchFn = *const fn (?*anyopaque, *const Request, *response.Capture) anyerror!void;
pub const StreamingDispatchFn = *const fn (?*anyopaque, *const Request, *response.Capture, ?streaming.Reader, *streaming.ByteQueue, *std.atomic.Value(bool), ?response.H2Wake, ?*anyopaque) anyerror!void;

const ReadFn = *const fn (*anyopaque, [*]u8, usize, c_int, c_int) callconv(.c) isize;
const ReadReadyFn = *const fn (*anyopaque, u32) callconv(.c) c_int;
const YieldFn = *const fn (*anyopaque) callconv(.c) c_int;
const WriteFn = *const fn (*anyopaque, [*]const u8, usize) callconv(.c) c_int;
const ShutdownFn = *const fn (*anyopaque) callconv(.c) c_int;
const DispatchStartFn = *const fn (*anyopaque, *const Request, *?*anyopaque) callconv(.c) c_int;
const DispatchPollFn = *const fn (*anyopaque, *anyopaque, *response.Capture) callconv(.c) c_int;
const DispatchCancelFn = *const fn (*anyopaque, *anyopaque) callconv(.c) void;
const DispatchTakeReadyFn = *const fn (*anyopaque) callconv(.c) ?*anyopaque;
const ReleaseFn = *const fn (*anyopaque, *response.Capture) callconv(.c) void;
const DispatchDataFn = *const fn (*anyopaque, *anyopaque, [*]const u8, usize, c_int) callconv(.c) c_int;
const ResponseReadFn = *const fn (*anyopaque, *anyopaque, [*]u8, usize, *c_int) callconv(.c) isize;
const ResponseReadyFn = *const fn (*anyopaque, *anyopaque) callconv(.c) c_int;

extern fn ziserver_nghttp2_version_text() [*:0]const u8;
extern fn ziserver_nghttp2_error_text(error_code: c_int) [*:0]const u8;
extern fn ziserver_nghttp2_serve(
    userdata: *anyopaque,
    read_fn: ReadFn,
    read_ready_fn: ReadReadyFn,
    yield_fn: YieldFn,
    write_fn: WriteFn,
    shutdown_fn: ShutdownFn,
    dispatch_start_fn: DispatchStartFn,
    dispatch_poll_fn: DispatchPollFn,
    dispatch_cancel_fn: DispatchCancelFn,
    dispatch_take_ready_fn: DispatchTakeReadyFn,
    release_fn: ReleaseFn,
    dispatch_data_fn: DispatchDataFn,
    response_read_fn: ResponseReadFn,
    response_ready_fn: ResponseReadyFn,
    max_header_bytes: usize,
    max_body_bytes: usize,
    max_requests: usize,
    summary: *Summary,
) c_int;

const ready_task_capacity = 128;

const Bridge = struct {
    connection: *transport.Connection,
    userdata: ?*anyopaque,
    dispatch: StreamingDispatchFn,
    stream_timeout_ms: u32,
    idle_timeout_ms: u32,
    stopping: ?*const std.atomic.Value(bool),
    deadline_initialized: bool = false,
    active_phase: bool = false,
    ready_mutex: std.Io.Mutex = .init,
    ready_tasks: [ready_task_capacity]?*DispatchTask = emptyReadyTasks(),
    ready_head: usize = 0,
    ready_len: usize = 0,
};

pub fn supportFromMode(mode: http_config.Http2Mode) Support {
    return switch (mode) {
        .off => .disabled,
        .reject => .reject_preface,
        .on => if (linked) .adapter else .disabled,
    };
}

pub fn shouldRejectPreface(mode: http_config.Http2Mode) bool {
    return supportFromMode(mode) == .reject_preface;
}

pub fn versionText() ?[:0]const u8 {
    if (!linked) return null;
    return std.mem.span(ziserver_nghttp2_version_text());
}

pub fn serve(
    connection: *transport.Connection,
    userdata: ?*anyopaque,
    dispatch: StreamingDispatchFn,
    max_requests: usize,
    stream_timeout_ms: u32,
    idle_timeout_ms: u32,
    stopping: ?*const std.atomic.Value(bool),
) !Summary {
    if (!linked) return error.Http2ProviderUnavailable;
    var bridge = Bridge{
        .connection = connection,
        .userdata = userdata,
        .dispatch = dispatch,
        .stream_timeout_ms = stream_timeout_ms,
        .idle_timeout_ms = idle_timeout_ms,
        .stopping = stopping,
    };
    var summary = Summary{};
    const result = ziserver_nghttp2_serve(
        &bridge,
        readBridge,
        readReadyBridge,
        yieldBridge,
        writeBridge,
        shutdownBridge,
        dispatchStartBridge,
        dispatchPollBridge,
        dispatchCancelBridge,
        dispatchTakeReadyBridge,
        releaseBridge,
        dispatchDataBridge,
        responseReadBridge,
        responseReadyBridge,
        http_config.max_header_bytes,
        http_config.max_stream_body_bytes,
        max_requests,
        &summary,
    );
    if (result != 0) {
        logger.message(
            connection.io,
            .err,
            "http2_session_failed",
            "code={d} error={s}",
            .{ result, std.mem.span(ziserver_nghttp2_error_text(result)) },
        );
        return error.Http2SessionFailed;
    }
    return summary;
}

fn readBridge(userdata: *anyopaque, buffer: [*]u8, len: usize, active_streams: c_int, pending_dispatches: c_int) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const active_phase = active_streams != 0;
    _ = pending_dispatches;
    if (!bridge.deadline_initialized or bridge.active_phase != active_phase) {
        bridge.connection.setReadTimeoutMs(if (active_phase) bridge.stream_timeout_ms else bridge.idle_timeout_ms);
        bridge.deadline_initialized = true;
        bridge.active_phase = active_phase;
    }
    var buffers: [1][]u8 = .{buffer[0..len]};
    const read = bridge.connection.read(&buffers) catch |err| switch (err) {
        error.ReadTimeout => return -2,
        error.GracefulShutdown => return -3,
        else => return -1,
    };
    return @intCast(read);
}

fn readReadyBridge(userdata: *anyopaque, timeout_ms: u32) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    return @intFromBool(bridge.connection.waitReadable(timeout_ms) catch return -1);
}

fn yieldBridge(_: *anyopaque) callconv(.c) c_int {
    std.Thread.yield() catch return -1;
    return 0;
}

fn writeBridge(userdata: *anyopaque, buffer: [*]const u8, len: usize) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    bridge.connection.writeAll(buffer[0..len]) catch return -1;
    return 0;
}

fn shutdownBridge(userdata: *anyopaque) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const stopping = bridge.stopping orelse return 0;
    return @intFromBool(stopping.load(.acquire));
}

const OwnedRequest = struct {
    method: []u8,
    path: []u8,
    authority: []u8,
    headers: []response.CapturedHeader,
    body: []u8,
    error_status: u16,

    fn init(source: *const Request) !OwnedRequest {
        const allocator = capture_allocator;
        const method = try allocator.dupe(u8, source.method());
        errdefer allocator.free(method);
        const path = try allocator.dupe(u8, source.path());
        errdefer allocator.free(path);
        const authority = try allocator.dupe(u8, source.authority());
        errdefer allocator.free(authority);
        const body = try allocator.dupe(u8, source.body());
        errdefer allocator.free(body);
        const headers = try allocator.alloc(response.CapturedHeader, source.headers().len);
        errdefer allocator.free(headers);
        var initialized: usize = 0;
        errdefer for (headers[0..initialized]) |header| {
            allocator.free(header.name_ptr[0..header.name_len]);
            allocator.free(header.value_ptr[0..header.value_len]);
        };
        for (source.headers(), headers) |header, *target| {
            const name = try allocator.dupe(u8, header.name_ptr[0..header.name_len]);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, header.value_ptr[0..header.value_len]);
            target.* = .{
                .name_ptr = name.ptr,
                .name_len = name.len,
                .value_ptr = value.ptr,
                .value_len = value.len,
            };
            initialized += 1;
        }
        return .{
            .method = method,
            .path = path,
            .authority = authority,
            .headers = headers,
            .body = body,
            .error_status = source.error_status,
        };
    }

    fn request(self: *const OwnedRequest) Request {
        return .{
            .method_ptr = if (self.method.len == 0) null else self.method.ptr,
            .method_len = self.method.len,
            .path_ptr = if (self.path.len == 0) null else self.path.ptr,
            .path_len = self.path.len,
            .authority_ptr = if (self.authority.len == 0) null else self.authority.ptr,
            .authority_len = self.authority.len,
            .headers_ptr = if (self.headers.len == 0) null else self.headers.ptr,
            .headers_len = self.headers.len,
            .body_ptr = if (self.body.len == 0) null else self.body.ptr,
            .body_len = self.body.len,
            .error_status = self.error_status,
        };
    }

    fn deinit(self: *OwnedRequest) void {
        const allocator = capture_allocator;
        for (self.headers) |header| {
            allocator.free(header.name_ptr[0..header.name_len]);
            allocator.free(header.value_ptr[0..header.value_len]);
        }
        allocator.free(self.headers);
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.authority);
        allocator.free(self.body);
    }
};

const DispatchTask = struct {
    bridge: *Bridge,
    request: OwnedRequest,
    captured: response.Capture = .{},
    done: std.atomic.Value(bool) = .init(false),
    headers_ready: std.atomic.Value(bool) = .init(false),
    headers_claimed: bool = false,
    future_awaited: bool = false,
    ready_enqueued: std.atomic.Value(bool) = .init(false),
    request_queue: streaming.ByteQueue,
    response_queue: streaming.ByteQueue,
    request_source: streaming.QueueSource,
    future: std.Io.Future(void) = undefined,
};

fn emptyReadyTasks() [ready_task_capacity]?*DispatchTask {
    var tasks: [ready_task_capacity]?*DispatchTask = undefined;
    @memset(&tasks, null);
    return tasks;
}

fn signalDispatchReady(task: *DispatchTask) void {
    if (task.ready_enqueued.swap(true, .acq_rel)) return;
    const bridge = task.bridge;
    bridge.ready_mutex.lockUncancelable(bridge.connection.io);
    defer bridge.ready_mutex.unlock(bridge.connection.io);
    if (bridge.ready_len == ready_task_capacity) {
        // This cannot occur while the adapter enforces its matching stream
        // limit. Leave the flag set: the task will be observed once a slot is
        // released and is never duplicated in the queue.
        return;
    }
    const tail = (bridge.ready_head + bridge.ready_len) % ready_task_capacity;
    bridge.ready_tasks[tail] = task;
    bridge.ready_len += 1;
}

fn responseWakeBridge(userdata: ?*anyopaque) void {
    const task: *DispatchTask = @ptrCast(@alignCast(userdata orelse return));
    signalDispatchReady(task);
}

fn dispatchTakeReadyBridge(userdata: *anyopaque) callconv(.c) ?*anyopaque {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    bridge.ready_mutex.lockUncancelable(bridge.connection.io);
    defer bridge.ready_mutex.unlock(bridge.connection.io);
    if (bridge.ready_len == 0) return null;
    const task = bridge.ready_tasks[bridge.ready_head] orelse return null;
    bridge.ready_tasks[bridge.ready_head] = null;
    bridge.ready_head = (bridge.ready_head + 1) % ready_task_capacity;
    bridge.ready_len -= 1;
    task.ready_enqueued.store(false, .release);
    return task;
}

fn removeDispatchReady(task: *DispatchTask) void {
    const bridge = task.bridge;
    task.ready_enqueued.store(false, .release);
    bridge.ready_mutex.lockUncancelable(bridge.connection.io);
    defer bridge.ready_mutex.unlock(bridge.connection.io);
    var compact = emptyReadyTasks();
    var kept: usize = 0;
    var offset: usize = 0;
    while (offset < bridge.ready_len) : (offset += 1) {
        const index = (bridge.ready_head + offset) % ready_task_capacity;
        const candidate = bridge.ready_tasks[index] orelse continue;
        if (candidate == task) continue;
        compact[kept] = candidate;
        kept += 1;
    }
    bridge.ready_tasks = compact;
    bridge.ready_head = 0;
    bridge.ready_len = kept;
}

fn runDispatchTask(task: *DispatchTask) void {
    var request = task.request.request();
    const reader = streaming.Reader.pull(&task.request_source, streaming.QueueSource.readerFn);
    task.bridge.dispatch(task.bridge.userdata, &request, &task.captured, reader, &task.response_queue, &task.headers_ready, responseWakeBridge, task) catch |err| {
        var target: response.Target = .{ .h2_stream = .{
            .response = &task.captured,
            .allocator = capture_allocator,
            .secure = true,
            .io = task.bridge.connection.io,
            .output = &task.response_queue,
            .headers_ready = &task.headers_ready,
            .wake_userdata = task,
            .wake = responseWakeBridge,
        } };
        _ = errors.write(&target, errors.kindFromError(err), false, false) catch {};
    };
    task.done.store(true, .release);
    // A published response is already represented by a ready task. Only
    // handlers that failed before publishing headers need a completion wake.
    if (!task.headers_ready.load(.acquire)) signalDispatchReady(task);
}

fn dispatchStartBridge(
    userdata: *anyopaque,
    request: *const Request,
    task_out: *?*anyopaque,
) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const task = capture_allocator.create(DispatchTask) catch return -1;
    const request_queue = streaming.ByteQueue.init(capture_allocator, http_config.max_form_body_bytes) catch {
        capture_allocator.destroy(task);
        return -1;
    };
    const response_queue = streaming.ByteQueue.init(capture_allocator, 64 * 1024) catch {
        var queue = request_queue;
        queue.deinit(bridge.connection.io);
        capture_allocator.destroy(task);
        return -1;
    };
    task.* = .{
        .bridge = bridge,
        .request = OwnedRequest.init(request) catch {
            var input = request_queue;
            var output = response_queue;
            input.deinit(bridge.connection.io);
            output.deinit(bridge.connection.io);
            capture_allocator.destroy(task);
            return -1;
        },
        .request_queue = request_queue,
        .response_queue = response_queue,
        .request_source = undefined,
    };
    task.request_source = .{ .io = bridge.connection.io, .queue = &task.request_queue };
    task.future = bridge.connection.io.async(runDispatchTask, .{task});
    task_out.* = task;
    return 0;
}

fn dispatchPollBridge(userdata: *anyopaque, opaque_task: *anyopaque, captured_response: *response.Capture) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const task: *DispatchTask = @ptrCast(@alignCast(opaque_task));
    if (task.headers_ready.load(.acquire) and !task.headers_claimed) {
        captured_response.* = task.captured;
        task.captured = .{};
        task.headers_claimed = true;
        return 2;
    }
    if (!task.done.load(.acquire)) return 0;
    if (!task.future_awaited) {
        task.future.await(bridge.connection.io);
        task.future_awaited = true;
    }
    return if (task.headers_claimed) 3 else -1;
}

fn dispatchCancelBridge(userdata: *anyopaque, opaque_task: *anyopaque) callconv(.c) void {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const task: *DispatchTask = @ptrCast(@alignCast(opaque_task));
    removeDispatchReady(task);
    task.request_queue.cancel(bridge.connection.io);
    task.response_queue.cancel(bridge.connection.io);
    if (!task.future_awaited) task.future.cancel(bridge.connection.io);
    task.captured.deinit(capture_allocator);
    task.request_queue.deinit(bridge.connection.io);
    task.response_queue.deinit(bridge.connection.io);
    task.request.deinit();
    capture_allocator.destroy(task);
}

fn dispatchDataBridge(userdata: *anyopaque, opaque_task: *anyopaque, data: [*]const u8, len: usize, end_stream: c_int) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const task: *DispatchTask = @ptrCast(@alignCast(opaque_task));
    if (len != 0) task.request_queue.push(bridge.connection.io, data[0..len]) catch |err| {
        logger.message(bridge.connection.io, .warn, "http2_request_stream_push_failed", "error={t}", .{err});
        return -1;
    };
    if (end_stream < 0) {
        task.request_queue.fail(bridge.connection.io, error.RequestBodyTooLarge);
    } else if (end_stream != 0) {
        task.request_queue.finish(bridge.connection.io);
    }
    return 0;
}

fn responseReadBridge(userdata: *anyopaque, opaque_task: *anyopaque, buffer: [*]u8, len: usize, end_out: *c_int) callconv(.c) isize {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const task: *DispatchTask = @ptrCast(@alignCast(opaque_task));
    end_out.* = 0;
    return switch (task.response_queue.readAvailable(bridge.connection.io, buffer[0..len])) {
        .data => |amount| block: {
            end_out.* = @intFromBool(task.response_queue.endedAndEmpty(bridge.connection.io));
            break :block @intCast(amount);
        },
        .pending => -2,
        .end => block: {
            end_out.* = 1;
            break :block 0;
        },
        .canceled => -1,
    };
}

fn responseReadyBridge(userdata: *anyopaque, opaque_task: *anyopaque) callconv(.c) c_int {
    const bridge: *Bridge = @ptrCast(@alignCast(userdata));
    const task: *DispatchTask = @ptrCast(@alignCast(opaque_task));
    return @intFromBool(task.response_queue.hasReadableOrEnded(bridge.connection.io));
}

fn releaseBridge(_: *anyopaque, captured_response: *response.Capture) callconv(.c) void {
    captured_response.deinit(capture_allocator);
}

test "http2 mode maps to provider support" {
    try std.testing.expectEqual(Support.disabled, supportFromMode(.off));
    try std.testing.expect(shouldRejectPreface(.reject));
    try std.testing.expectEqual(if (linked) Support.adapter else Support.disabled, supportFromMode(.on));
}

test "http2 summary exposes graceful goaway state" {
    try std.testing.expect(!(Summary{}).sentGoaway());
    try std.testing.expect((Summary{ .goaway_sent = 1 }).sentGoaway());
}

test "http2 async dispatch owns a deep request copy" {
    var method = [_]u8{ 'P', 'O', 'S', 'T' };
    var path = [_]u8{ '/', 'e', 'c', 'h', 'o' };
    var authority = [_]u8{ 'e', 'x', 'a', 'm', 'p', 'l', 'e' };
    var header_name = [_]u8{ 'x', '-', 't', 'e', 's', 't' };
    var header_value = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var body = [_]u8{ 'd', 'a', 't', 'a' };
    var headers = [_]response.CapturedHeader{.{
        .name_ptr = &header_name,
        .name_len = header_name.len,
        .value_ptr = &header_value,
        .value_len = header_value.len,
    }};
    const source = Request{
        .method_ptr = &method,
        .method_len = method.len,
        .path_ptr = &path,
        .path_len = path.len,
        .authority_ptr = &authority,
        .authority_len = authority.len,
        .headers_ptr = &headers,
        .headers_len = headers.len,
        .body_ptr = &body,
        .body_len = body.len,
        .error_status = 418,
    };
    var owned = try OwnedRequest.init(&source);
    defer owned.deinit();

    @memset(&method, 'x');
    @memset(&path, 'x');
    @memset(&authority, 'x');
    @memset(&header_name, 'x');
    @memset(&header_value, 'x');
    @memset(&body, 'x');

    const copied = owned.request();
    try std.testing.expectEqualStrings("POST", copied.method());
    try std.testing.expectEqualStrings("/echo", copied.path());
    try std.testing.expectEqualStrings("example", copied.authority());
    try std.testing.expectEqualStrings("x-test", copied.headers()[0].name_ptr[0..copied.headers()[0].name_len]);
    try std.testing.expectEqualStrings("value", copied.headers()[0].value_ptr[0..copied.headers()[0].value_len]);
    try std.testing.expectEqualStrings("data", copied.body());
    try std.testing.expectEqual(@as(u16, 418), copied.error_status);
}

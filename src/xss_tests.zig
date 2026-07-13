const xss = @import("compose/xss.zig");
const request_mod = @import("core/request.zig");
const std = @import("std");

test "detects common script injection markers" {
    try std.testing.expect(xss.containsSuspiciousInput("name=<script>alert(1)</script>"));
    try std.testing.expect(xss.containsSuspiciousInput("url=javascript:alert(1)"));
    try std.testing.expect(xss.containsSuspiciousInput("img=%3Cscript%3Ealert(1)"));
    try std.testing.expect(!xss.containsSuspiciousInput("name=normal&message=hello"));
}

test "policy can disable request inspection" {
    const request = try request_mod.Request.parse(
        "POST /submit?q=<script HTTP/1.1\r\nContent-Length: 18\r\n\r\nname=<script>x</script>",
    );
    try std.testing.expectEqual(@as(?xss.Violation, null), xss.inspectRequest(request, .{}));
    try std.testing.expectEqual(xss.Violation.suspected_xss, xss.inspectRequest(request, .{ .mode = .observe }));
}

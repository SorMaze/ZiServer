const std = @import("std");

const Context = @import("../ziserver.zig").Context;

const DemoPage = struct {
    slug: []const u8,
    title: []const u8,
    eyebrow: []const u8,
    body: []const u8,
    metric_label: []const u8,
    metric_value: []const u8,
    code: []const u8,
    cards: [3]DemoCard,
    extra: []const u8 = "",
};

const DemoCard = struct {
    title: []const u8,
    body: []const u8,
};

const demo_pages = [_]DemoPage{
    .{
        .slug = "home",
        .title = "Trust the edge, own the lifecycle",
        .eyebrow = "July 2026 · Identity · Redirects · HTTP/2 · Lifecycle",
        .body = "ZiServer now resolves one trustworthy client identity from the socket edge, applies bounded per-IP limits, and keeps request authority out of protocol redirects. A fallible allocator-aware application factory completes the boundary: app resources initialize explicitly, serve through core, then deinitialize in a defined order.",
        .metric_label = "Production boundaries",
        .metric_value = "1 client IP · 1 Host policy · 0 global budget",
        .code = "zig build run -- \\\n  --host=0.0.0.0 \\\n  --canonical-host=server.lan \\\n  --client-ip-header=x-forwarded-for \\\n  --trusted-proxy=192.168.31.0/24",
        .cards = .{
            .{ .title = "Identity from evidence", .body = "Peer IP is authoritative by default; forwarded chains are accepted only from bounded trusted CIDRs." },
            .{ .title = "Redirects without reflection", .body = "Canonical and allowed hosts decide Location; unknown authority receives 400 instead of becoming a target." },
            .{ .title = "HTTP/2 stays multiplexed", .body = "Redirected POST bodies drain independently, so one abandoned stream cannot stall the whole session." },
        },
    },
    .{
        .slug = "about",
        .title = "Core starts services. Compose adds policy.",
        .eyebrow = "Main → Core · App factory injected",
        .body = "main.zig only hands process initialization and the concrete app factory to core. core/ owns startup, listeners, workers and shutdown; compose/ remains a slower policy layer consumed by the app. The dependency direction never asks core to bootstrap compose.",
        .metric_label = "Startup direction",
        .metric_value = "main → core.start(factory)",
        .code = "main.zig\n└─ core.server.start(init, app.buildApplication)\n   ├─ listeners + workers\n   ├─ app factory(allocator, startup)!\n   └─ ApplicationBundle.deinit()",
        .cards = .{
            .{ .title = "core/ owns startup", .body = "Configuration, transport, protocols, queues, workers, runtime resources and graceful shutdown." },
            .{ .title = "compose/ owns policy", .body = "Content, uploads, cache, auth, rate limits and database leases build on core contracts." },
            .{ .title = "app/ owns resources", .body = "A fallible factory can create pools, templates or plugins and return their cleanup contract." },
        },
    },
    .{
        .slug = "products",
        .title = "Policy reads where behavior lives",
        .eyebrow = "App-side DSL",
        .body = "Route builders compose content extraction, cache, uploads, database leases and security policy after core has resolved client identity. Groups still lower into a flat router table at compile time, so readable app declarations do not create a second runtime router.",
        .metric_label = "Composable layers",
        .metric_value = "extract + inject + cache + database",
        .code = "h.post(\"/files/metadata\", save)\n  .withLayers(.{\n    z.layer.content(.{\n      .request = .json, .response = .json,\n      .max_request_bytes = 4096,\n    }),\n    z.layer.database(.required),\n  });",
        .cards = .{
            .{ .title = "Content-aware", .body = "Use content(), or compose extract() and inject() when request and response formats differ." },
            .{ .title = "Storage-aware", .body = "Small and streaming file landing are opt-in route policy rather than handler convention." },
            .{ .title = "Identity-aware", .body = "Rate policy consumes the verified client IP; handlers never need to reinterpret proxy headers." },
        },
    },
    .{
        .slug = "api",
        .title = "One document path, any representation",
        .eyebrow = "Interactive Content Lab",
        .body = "The content middleware validates media type and bounded input, then exposes a borrowed Document to the handler. Built-ins cover JSON, XML, HTML, TOML and opaque bytes; app codecs can register their own extractor and injector without entering core.",
        .metric_label = "Live endpoints",
        .metric_value = "5 live format routes",
        .code = "const doc = z.content.document(ctx) orelse\n  return error.InvalidContentEncoding;\n\ntry z.content.injectDocument(\n  ctx, .ok, doc, .no_cache,\n);",
        .cards = .{
            .{ .title = "Borrow, do not copy", .body = "Document points at the bounded request buffer; typed parsing stays explicit in app code." },
            .{ .title = "Fail closed", .body = "MIME mismatches return 415; invalid representations return a stable 400 error." },
            .{ .title = "Try it below", .body = "Switch formats, edit the payload, and inspect the live status, MIME, bytes, and body." },
        },
        .extra = content_lab_markup,
    },
    .{
        .slug = "security",
        .title = "Trust begins at the socket, not the header",
        .eyebrow = "Peer IP · Trusted proxies · Redirect Host",
        .body = "The direct peer is the identity boundary. Forwarded addresses become authoritative only when the peer matches an explicit CIDR, then a bounded sharded limiter counts by normalized client IP. Protocol redirects resolve Location separately from transport writes and never reflect an unapproved Host.",
        .metric_label = "Redirect outcome",
        .metric_value = "canonical 308 · unknown Host 400",
        .code = "--client-ip-header=x-forwarded-for\n--trusted-proxy=10.0.0.0/8\n--rate-limit-strict=20\n--canonical-host=app.example\n--allowed-host=app.example",
        .cards = .{
            .{ .title = "Proxy boundary", .body = "Untrusted peers cannot spend another client's budget by spoofing X-Forwarded-For." },
            .{ .title = "Bounded limiter", .body = "Capacity, shards and idle eviction bound memory while relaxed and strict policies remain separate." },
            .{ .title = "Safe redirect adapter", .body = "Validation errors become 400; socket and H2 output failures propagate without a second response." },
        },
        .extra = security_boundary_markup,
    },
    .{
        .slug = "contact",
        .title = "Initialize, serve, drain, deinitialize",
        .eyebrow = "Application + Core Lifecycle",
        .body = "The application factory receives the process allocator and startup policy, may fail without panicking, and returns an ApplicationBundle with optional state cleanup. During shutdown, acceptors wake and stop, HTTP/2 sends GOAWAY, active work drains, then app-owned resources release before core stores and the process allocator.",
        .metric_label = "Lifecycle contract",
        .metric_value = "factory! → serve → GOAWAY → deinit",
        .code = "fn buildApplication(allocator, startup) !ApplicationBundle {\n  var state = try AppState.init(allocator);\n  errdefer state.deinit();\n  return .{ .application = app, .state = &state,\n    .deinit_fn = deinitApplication };\n}",
        .cards = .{
            .{ .title = "Fallible initialization", .body = "Pools, templates and plugins can return errors and clean partial state with errdefer." },
            .{ .title = "Graceful by protocol", .body = "HTTP/1 stops reuse; HTTP/2 drains accepted streams after GOAWAY within the grace deadline." },
            .{ .title = "Deterministic cleanup", .body = "ApplicationBundle cleanup runs before rate limiter, page cache and allocator teardown." },
        },
    },
};

pub fn handle(ctx: *Context) !void {
    const slug = ctx.param("page") orelse ctx.queryParam("page") orelse slugFromPath(ctx.request.path);
    const page = findDemoPage(slug) orelse {
        try writeMissingDemoPage(ctx, slug);
        return;
    };

    var html_buffer: [24 * 1024]u8 = undefined;
    const html = try std.fmt.bufPrint(
        &html_buffer,
        demo_template,
        .{
            page.title,
            page.slug,
            navClass(page.slug, "home"),
            navClass(page.slug, "about"),
            navClass(page.slug, "products"),
            navClass(page.slug, "api"),
            navClass(page.slug, "security"),
            navClass(page.slug, "contact"),
            page.eyebrow,
            page.title,
            page.body,
            page.metric_label,
            page.metric_value,
            page.code,
            page.cards[0].title,
            page.cards[0].body,
            page.cards[1].title,
            page.cards[1].body,
            page.cards[2].title,
            page.cards[2].body,
            page.extra,
        },
    );

    try ctx.html(.ok, html);
}

fn slugFromPath(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/site")) return "home";
    if (std.mem.startsWith(u8, path, "/site/")) return path["/site/".len..];
    if (path.len > 1 and path[0] == '/') return path[1..];
    return "home";
}

fn findDemoPage(slug: []const u8) ?DemoPage {
    for (demo_pages) |page| {
        if (std.mem.eql(u8, page.slug, slug)) return page;
    }
    return null;
}

fn navClass(active: []const u8, current: []const u8) []const u8 {
    return if (std.mem.eql(u8, active, current)) "active" else "";
}

fn writeMissingDemoPage(ctx: *Context, slug: []const u8) !void {
    var escaped_slug_buffer: [256]u8 = undefined;
    const escaped_slug = escapeHtml(slug, &escaped_slug_buffer);
    var html_buffer: [2048]u8 = undefined;
    const html = try std.fmt.bufPrint(
        &html_buffer,
        missing_demo_template,
        .{ escaped_slug, escaped_slug },
    );
    try ctx.html(.not_found, html);
}

fn escapeHtml(input: []const u8, buffer: []u8) []const u8 {
    var out: usize = 0;
    for (input) |byte| {
        const replacement = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (replacement) |text| {
            if (out + text.len > buffer.len) break;
            @memcpy(buffer[out .. out + text.len], text);
            out += text.len;
        } else {
            if (out + 1 > buffer.len) break;
            buffer[out] = byte;
            out += 1;
        }
    }
    return buffer[0..out];
}

const content_lab_markup =
    "<section class=\"playground\" id=\"content-lab\">" ++
    "<div class=\"section-head\"><div><p class=\"eyebrow\">Live request</p><h2>Content playground</h2></div><p>This form posts directly to the current ZiServer process. The response is rendered as text, never inserted as HTML.</p></div>" ++
    "<form id=\"content-form\" class=\"lab-grid\">" ++
    "<div class=\"lab-panel\"><div class=\"lab-row\"><label>Representation<select id=\"content-format\"><option value=\"json\" data-mime=\"application/json\">JSON</option><option value=\"xml\" data-mime=\"application/xml\">XML</option><option value=\"html\" data-mime=\"text/html\">HTML</option><option value=\"toml\" data-mime=\"application/toml\">TOML</option><option value=\"binary\" data-mime=\"application/octet-stream\">Binary bytes</option></select></label><label>Target<input id=\"content-target\" value=\"/content/json\" readonly></label></div><label>Request body<textarea id=\"content-body\" spellcheck=\"false\">{\"project\":\"ZiServer\",\"ready\":true}</textarea></label><button id=\"content-send\" type=\"submit\">Send through middleware</button></div>" ++
    "<div class=\"lab-panel\"><div class=\"lab-meta\"><span id=\"content-status-dot\" class=\"status-dot\"></span><span id=\"content-meta\">Waiting for a request</span></div><pre id=\"content-output\" class=\"lab-output\">Select a representation, edit the payload, then send it through the shared HTTP/1.1 / HTTP/2 route pipeline.</pre></div>" ++
    "</form></section>";

const security_boundary_markup =
    "<section class=\"playground trust-boundary\" id=\"trust-boundary\">" ++
    "<div class=\"section-head\"><div><p class=\"eyebrow\">Request trust path</p><h2>One decision at each boundary</h2></div><p>The runtime separates transport evidence, proxy trust, rate accounting and redirect output instead of treating Host or forwarding headers as ambient truth.</p></div>" ++
    "<div class=\"trust-flow\">" ++
    "<article class=\"trust-step\"><small>01 · socket</small><b>Capture peer IP</b><span>The accepted socket supplies the default client identity for HTTP/1.1 and HTTP/2.</span></article>" ++
    "<article class=\"trust-step\"><small>02 · proxy</small><b>Verify the sender</b><span>XFF is parsed only when the direct peer belongs to an explicit trusted CIDR.</span></article>" ++
    "<article class=\"trust-step\"><small>03 · policy</small><b>Spend one IP budget</b><span>The normalized client IP and route policy select a bounded limiter bucket.</span></article>" ++
    "<article class=\"trust-step\"><small>04 · redirect</small><b>Resolve before write</b><span>Canonical or allowed hosts produce Location; an unknown authority stops at 400.</span></article>" ++
    "</div>" ++
    "<div class=\"policy-table-wrap\"><table class=\"policy-table\"><thead><tr><th>Listener policy</th><th>Request authority</th><th>Result</th></tr></thead><tbody>" ++
    "<tr><td>canonical = app.example</td><td>attacker.example</td><td><strong>308</strong> to app.example</td></tr>" ++
    "<tr><td>allowed = app.example</td><td>attacker.example</td><td><strong>400</strong> rejected</td></tr>" ++
    "<tr><td>wildcard TLS, no policy</td><td>any</td><td><strong>startup refused</strong></td></tr>" ++
    "</tbody></table></div></section>";

const demo_template =
    "<!doctype html>\n" ++
    "<html lang=\"en\">\n" ++
    "<head>\n" ++
    "  <meta charset=\"utf-8\">\n" ++
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
    "  <title>{s}</title>\n" ++
    "  <style>\n" ++
    "    html {{ visibility: hidden; }}\n" ++
    "    :root {{ color-scheme: light; font-family: Inter, Segoe UI, system-ui, sans-serif; color: #17202a; background: #f4f7f8; }}\n" ++
    "    body {{ margin: 0; min-height: 100vh; background: linear-gradient(180deg,#f8faf8 0,#edf3f5 58%,#f6f4ef 100%); }}\n" ++
    "    header {{ display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 22px clamp(18px, 4vw, 54px); border-bottom: 1px solid #d7e0e3; background: rgba(255,255,255,.72); backdrop-filter: blur(10px); }}\n" ++
    "    .brand {{ font-weight: 850; font-size: 18px; letter-spacing: 0; }}\n" ++
    "    nav {{ display: flex; flex-wrap: wrap; gap: 8px; }}\n" ++
    "    nav a {{ color: #2d3b45; text-decoration: none; padding: 8px 10px; border-radius: 6px; }}\n" ++
    "    nav a.active {{ background: #1d2930; color: #fff; }}\n" ++
    "    main {{ display: grid; grid-template-columns: minmax(0, 1fr) minmax(280px, 420px); gap: clamp(28px, 6vw, 76px); align-items: center; padding: clamp(42px, 8vw, 90px) clamp(18px, 4vw, 54px) 28px; max-width: 1440px; margin: 0 auto; }}\n" ++
    "    .eyebrow {{ margin: 0 0 14px; color: #386a74; font-weight: 780; text-transform: uppercase; font-size: 13px; }}\n" ++
    "    h1 {{ margin: 0; max-width: 820px; font-size: clamp(38px, 6vw, 72px); line-height: 1; letter-spacing: 0; }}\n" ++
    "    p {{ max-width: 66ch; margin: 22px 0 0; color: #40515a; font-size: 19px; line-height: 1.7; }}\n" ++
    "    .actions {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 28px; }}\n" ++
    "    .actions a {{ color: #fff; background: #1d2930; text-decoration: none; padding: 10px 12px; border-radius: 6px; font-weight: 760; }}\n" ++
    "    .actions a.secondary {{ color: #1d2930; background: #dfe9ec; }}\n" ++
    "    .visual {{ min-height: 330px; display: grid; align-content: center; gap: 18px; background: #22313a; color: #f7fbff; border-radius: 8px; box-shadow: 0 24px 70px rgba(29,41,48,.18); padding: 26px; }}\n" ++
    "    .metric {{ display: grid; gap: 10px; }}\n" ++
    "    .metric small {{ color: #9fd4d7; font-weight: 760; text-transform: uppercase; }}\n" ++
    "    .metric strong {{ font-size: clamp(30px, 4vw, 46px); line-height: 1.05; overflow-wrap: anywhere; }}\n" ++
    "    .code {{ margin: 0; padding: 14px; border-radius: 6px; background: #101820; color: #d8f2e5; overflow: auto; font: 14px/1.55 Consolas, ui-monospace, monospace; }}\n" ++
    "    .band {{ padding: 0 clamp(18px, 4vw, 54px) clamp(34px, 5vw, 56px); display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 14px; max-width: 1440px; margin: 0 auto; }}\n" ++
    "    .item {{ border-top: 3px solid #2f7a8a; background: rgba(255,255,255,.78); padding: 18px; border-radius: 8px; }}\n" ++
    "    .item b {{ display: block; margin-bottom: 8px; }}\n" ++
    "    .item span {{ color: #53646c; line-height: 1.55; }}\n" ++
    "    header a {{ transition: box-shadow .2s ease, transform .2s ease; }}\n" ++
    "    header a:hover {{ transform: scale(1.04); }}\n" ++
    "    .actions a {{ transition: box-shadow .25s ease; }}\n" ++
    "    .actions a:hover {{ transform: scale(1.03); box-shadow: 0 8px 22px rgba(29,41,48,.35); }}\n" ++
    "    .visual {{ transition: box-shadow .4s ease; }}\n" ++
    "    .item {{ transition: box-shadow .3s ease; }}\n" ++
    "    .item:hover {{ transform: translateY(-2px); box-shadow: 0 12px 36px rgba(29,41,48,.12); }}\n" ++
    "    .updates, .playground {{ max-width: 1332px; margin: 0 auto clamp(42px,7vw,84px); padding: clamp(24px,4vw,44px); border: 1px solid #d4dfe2; border-radius: 12px; background: rgba(255,255,255,.72); box-sizing: border-box; }}\n" ++
    "    .section-head {{ display: flex; justify-content: space-between; align-items: end; gap: 24px; margin-bottom: 24px; }}\n" ++
    "    .section-head .eyebrow {{ margin-bottom: 7px; }}\n" ++
    "    .section-head h2 {{ margin: 0; font-size: clamp(28px,4vw,46px); line-height: 1.05; }}\n" ++
    "    .section-head > p {{ margin: 0; max-width: 46ch; font-size: 15px; line-height: 1.55; }}\n" ++
    "    .update-grid {{ display: grid; grid-template-columns: repeat(4,minmax(0,1fr)); gap: 12px; }}\n" ++
    "    .update-card {{ padding: 18px; border-radius: 9px; background: #f4f8f8; border: 1px solid #dbe6e8; }}\n" ++
    "    .update-card small {{ display: inline-block; margin-bottom: 20px; color: #2f6f7b; font: 750 11px/1 ui-monospace,monospace; letter-spacing: .08em; text-transform: uppercase; }}\n" ++
    "    .update-card b {{ display: block; margin-bottom: 8px; font-size: 17px; }}\n" ++
    "    .update-card span {{ color: #53646c; line-height: 1.5; font-size: 14px; }}\n" ++
    "    .update-links {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 18px; }}\n" ++
    "    .update-links a {{ color: #1d2930; background: #dfeaec; text-decoration: none; padding: 9px 11px; border-radius: 6px; font-weight: 760; }}\n" ++
    "    .playground {{ background: #18252c; color: #f5fbfc; border-color: #29414b; }}\n" ++
    "    .playground .eyebrow, .playground .section-head > p {{ color: #9fd4d7; }}\n" ++
    "    .lab-grid {{ display: grid; grid-template-columns: minmax(0,1fr) minmax(0,1fr); gap: 18px; }}\n" ++
    "    .lab-panel {{ display: grid; gap: 12px; align-content: start; }}\n" ++
    "    .lab-panel label {{ color: #b8cbd0; font-size: 13px; font-weight: 750; }}\n" ++
    "    .lab-row {{ display: flex; flex-wrap: wrap; gap: 10px; }}\n" ++
    "    .lab-row > * {{ flex: 1 1 170px; }}\n" ++
    "    .playground select, .playground input, .playground textarea, .playground button {{ font: inherit; border-radius: 7px; }}\n" ++
    "    .playground select, .playground input, .playground textarea {{ width: 100%; box-sizing: border-box; border: 1px solid #47616b; background: #0f191e; color: #eaf5f6; padding: 11px 12px; }}\n" ++
    "    .playground input[readonly] {{ color: #9fd4d7; }}\n" ++
    "    .playground textarea {{ min-height: 170px; resize: vertical; font: 14px/1.55 Consolas,ui-monospace,monospace; }}\n" ++
    "    .playground button {{ border: 0; padding: 11px 14px; background: #9fd4d7; color: #132027; font-weight: 800; cursor: pointer; }}\n" ++
    "    .playground button:disabled {{ opacity: .55; cursor: wait; }}\n" ++
    "    .lab-meta {{ min-height: 22px; color: #9fd4d7; font: 12px/1.5 ui-monospace,monospace; }}\n" ++
    "    .lab-output {{ min-height: 218px; margin: 0; padding: 14px; overflow: auto; border: 1px solid #304852; border-radius: 7px; background: #0c1418; color: #d8f2e5; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.55 Consolas,ui-monospace,monospace; }}\n" ++
    "    .status-dot {{ display: inline-block; width: 8px; height: 8px; margin-right: 7px; border-radius: 50%; background: #768b92; }}\n" ++
    "    .status-dot.ok {{ background: #69d39b; box-shadow: 0 0 0 4px rgba(105,211,155,.12); }}\n" ++
    "    .status-dot.error {{ background: #ff8c78; box-shadow: 0 0 0 4px rgba(255,140,120,.12); }}\n" ++
    "    .trust-flow {{ display: grid; grid-template-columns: repeat(4,minmax(0,1fr)); gap: 10px; }}\n" ++
    "    .trust-step {{ position: relative; display: grid; align-content: start; gap: 9px; min-height: 142px; padding: 18px; border: 1px solid #304852; border-radius: 8px; background: #101a1f; }}\n" ++
    "    .trust-step small {{ color: #9fd4d7; font: 750 11px/1 ui-monospace,monospace; letter-spacing: .08em; text-transform: uppercase; }}\n" ++
    "    .trust-step b {{ font-size: 17px; }}\n" ++
    "    .trust-step span {{ color: #b8cbd0; font-size: 14px; line-height: 1.5; }}\n" ++
    "    .policy-table-wrap {{ margin-top: 18px; overflow-x: auto; border: 1px solid #304852; border-radius: 8px; }}\n" ++
    "    .policy-table {{ width: 100%; border-collapse: collapse; min-width: 620px; background: #0c1418; }}\n" ++
    "    .policy-table th, .policy-table td {{ padding: 13px 15px; border-bottom: 1px solid #263b44; text-align: left; font-size: 14px; }}\n" ++
    "    .policy-table th {{ color: #9fd4d7; font: 750 11px/1 ui-monospace,monospace; letter-spacing: .08em; text-transform: uppercase; }}\n" ++
    "    .policy-table tr:last-child td {{ border-bottom: 0; }}\n" ++
    "    a:focus-visible, button:focus-visible, select:focus-visible, textarea:focus-visible {{ outline: 3px solid #69d39b; outline-offset: 3px; }}\n" ++
    "    @media (min-width: 1400px) {{ main {{ grid-template-columns: minmax(0, 1.2fr) minmax(340px, 520px); }} .visual {{ padding: 34px 38px; }} }}\n" ++
    "    @media (min-width: 1800px) {{ main {{ grid-template-columns: minmax(0, 1.4fr) minmax(380px, 620px); gap: 90px; }} .visual {{ padding: 40px 48px; min-height: 380px; }} }}\n" ++
    "    @media (max-width: 980px) {{ .update-grid, .trust-flow {{ grid-template-columns: repeat(2,minmax(0,1fr)); }} }}\n" ++
    "    @media (max-width: 860px) {{ header, main {{ display: block; }} nav {{ margin-top: 16px; }} .visual {{ margin-top: 32px; min-height: 240px; }} .band, .lab-grid {{ grid-template-columns: 1fr; }} .section-head {{ display: block; }} .section-head > p {{ margin-top: 12px; }} .updates, .playground {{ margin-left: 18px; margin-right: 18px; }} }}\n" ++
    "    @media (max-width: 560px) {{ .update-grid, .trust-flow {{ grid-template-columns: 1fr; }} }}\n" ++
    "  </style>\n" ++
    "</head>\n" ++
    "<body data-page=\"{s}\">\n" ++
    "  <header><div class=\"brand\">ZiServer Runtime Lab</div><nav><a class=\"{s}\" href=\"/\">Home</a><a class=\"{s}\" href=\"/about\">Architecture</a><a class=\"{s}\" href=\"/products\">DSL</a><a class=\"{s}\" href=\"/api\">API</a><a class=\"{s}\" href=\"/security\">Security</a><a class=\"{s}\" href=\"/contact\">Lifecycle</a></nav></header>\n" ++
    "  <main><section><p class=\"eyebrow\">{s}</p><h1>{s}</h1><p>{s}</p><div class=\"actions\"><a href=\"/health\">Health</a><a class=\"secondary\" href=\"/stats\">Stats JSON</a><a class=\"secondary\" href=\"/security#trust-boundary\">Trust boundary</a></div></section><aside class=\"visual\"><div class=\"metric\"><small>{s}</small><strong>{s}</strong></div><pre class=\"code\">{s}</pre></aside></main>\n" ++
    "  <section class=\"band\"><div class=\"item\"><b>{s}</b><span>{s}</span></div><div class=\"item\"><b>{s}</b><span>{s}</span></div><div class=\"item\"><b>{s}</b><span>{s}</span></div></section>\n" ++
    "  <section class=\"updates\"><div class=\"section-head\"><div><p class=\"eyebrow\">Current safety map</p><h2>What now holds the boundary</h2></div><p>Transport evidence, request policy and application lifecycle are explicit contracts shared by HTTP/1.1 and HTTP/2.</p></div><div class=\"update-grid\"><article class=\"update-card\"><small>identity</small><b>Trusted client IP</b><span>Peer-first resolution, bounded proxy chains and CIDR trust feed one normalized identity into middleware.</span></article><article class=\"update-card\"><small>redirect</small><b>Canonical Host policy</b><span>Canonical, allowlist and concrete-bind fallback rules keep attacker authority out of Location.</span></article><article class=\"update-card\"><small>http/2</small><b>Stream-safe redirects</b><span>Redirected request bodies keep draining while response transport failures remain real I/O errors.</span></article><article class=\"update-card\"><small>lifecycle</small><b>ApplicationBundle</b><span>Allocator-aware fallible startup and optional deinit state support pools, templates and plugins.</span></article></div><div class=\"update-links\"><a href=\"/security#trust-boundary\">Inspect trust boundary</a><a href=\"/api#content-lab\">Open content lab</a><a href=\"/stream-demo.html\">Run stream demo</a><a href=\"/stats\">Inspect live stats</a></div></section>\n" ++
    "  {s}\n" ++
    "  <script src=\"/assets/gsap.min.js?v=site7\"></script>\n" ++
    "  <script src=\"/assets/ScrollTrigger.min.js?v=site7\"></script>\n" ++
    "  <script src=\"/assets/app.js?v=site7\"></script>\n" ++
    "</body>\n" ++
    "</html>\n";

const missing_demo_template =
    "<!doctype html>\n" ++
    "<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Missing page</title><style>html{{visibility:hidden}}</style></head>\n" ++
    "<body style=\"font-family: Inter, Segoe UI, system-ui, sans-serif; margin: 48px; color: #17202a; background: #f6f7f2;\">\n" ++
    "<main style=\"max-width: 680px;\"><p style=\"color:#65705f;font-weight:750;text-transform:uppercase;\">Dynamic route 404</p><h1 style=\"font-size:48px;line-height:1;\">No demo page named {s}</h1><p>The path parameter was matched, but no page data exists for <code>{s}</code>.</p><p><a href=\"/\" style=\"display:inline-block;color:#fff;background:#1d2930;text-decoration:none;padding:10px 12px;border-radius:6px;font-weight:760;\">Back to site</a></p></main>\n" ++
    "<script src=\"/assets/gsap.min.js?v=site7\"></script>\n" ++
    "<script src=\"/assets/app.js?v=site7\"></script>\n" ++
    "</body></html>\n";

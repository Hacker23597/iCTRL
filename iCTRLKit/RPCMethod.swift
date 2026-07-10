import Foundation

struct RPCParamDef: Encodable {
    let name: String
    let type: String
    let required: Bool
    let description: String
}

struct RPCMethodDef: Encodable {
    let name: String
    let description: String
    let params: [RPCParamDef]
    let returns: String
}

struct RPCMethodRegistry {
    static let methods: [RPCMethodDef] = [
        RPCMethodDef(
            name: "config",
            description: "Read or update server settings and manage authorized sessions. With no params: returns current config plus the list of authorized sessions (client name, masked token prefix, granted/expiry times). Pass allow_remote_access and/or listen_port to change settings (persisted; server restarts, dropping the connection — reconnect at the returned address). Pass revoke_session_id to remove one session, or clear_sessions=true to revoke ALL tokens (including your own). Pass stop_server=true to SHUT DOWN the service (stops listening after replying; re-launch the runner to restart — tokens are preserved so no re-auth is needed).",
            params: [
                RPCParamDef(name: "allow_remote_access", type: "boolean", required: false, description: "true = listen on all interfaces (LAN reachable); false = 127.0.0.1 only"),
                RPCParamDef(name: "listen_port", type: "number", required: false, description: "TCP port to listen on (1..65535, default 8200)"),
                RPCParamDef(name: "revoke_session_id", type: "string", required: false, description: "session_id of a single authorization to revoke"),
                RPCParamDef(name: "clear_sessions", type: "boolean", required: false, description: "true = revoke all authorized tokens immediately"),
                RPCParamDef(name: "stop_server", type: "boolean", required: false, description: "true = stop the service (stops listening ~1s after replying). Re-launch the runner to restart; tokens persist."),
            ],
            returns: "{allow_remote_access, listen_port, address, restarted, device_name, active_sessions, sessions:[{session_id, client_name, token_prefix, granted_at, last_active_at, expires_at}], cleared_sessions}"
        ),
        RPCMethodDef(
            name: "device_info",
            description: "Get device name, model, OS version, the coordinate space (point size for tap/swipe, pixel size for screenshots, scale), AND the server's identity: server_version, protocol_version, and a capabilities array — so ONE device_info call gives you both the device and what this server supports (no separate /schema fetch for feature detection). CALL THIS FIRST before any coordinate-based action.",
            params: [],
            returns: "Object with point_width/point_height (tap space), pixel_width/pixel_height (screenshot space), scale, a 'hint' string, plus server_version (semver), protocol_version (int), and capabilities (array of feature tags, e.g. bearer_auth, find_element_ref, clear_text, page, stop_server)."
        ),
        RPCMethodDef(
            name: "page_source",
            description: "Inspect the current UI: returns the accessibility/view hierarchy as text (element types, labels, identifiers, frames in POINTS). Use it to UNDERSTAND layout — NOT as your locate-and-tap loop. To act on a control you already know by label, do NOT read its frame and tap x,y; call find_element{element_id:<label>} → tap{ref} (a ref survives scroll/animation, needs no coordinate math, and no re-read to re-derive coords). Reserve coordinate taps for elements with no usable label. On rich pages the full tree is large and the first call after a launch can be slow while the UI settles — scope it: filter returns only matching nodes+ancestors (also great for HARVESTING repeated data — filter by a substring common to the values you want), max_elements caps the count. 500-node hard cap by default (truncated:true when hit). Use screenshot only when an element is missing here or you need visual detail.",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "Inspect this app's tree; omit for the detected foreground app"),
                RPCParamDef(name: "filter", type: "object", required: false, description: "Return only matching nodes + their ancestors. {label:'<substring>'} (label/value substring, case-insensitive), {type:'button'} (element type), or {text:'<substring>'} (label+value+id substring). Also the cheapest way to HARVEST repeated data — filter by a substring common to the values you want, far easier than parsing the whole tree."),
                RPCParamDef(name: "max_depth", type: "number", required: false, description: "Max tree depth. WARNING: labels/tappable controls live near the LEAVES, so a shallow depth (3-4) returns structure with NO useful labels and you'll have to re-fetch — a wasted call. Use max_depth ONLY to preview overall layout; to FIND an element use filter or find_element instead."),
                RPCParamDef(name: "max_elements", type: "number", required: false, description: "Max nodes to return (default 500, hard cap 2000). If hit, response is truncated:true"),
            ],
            returns: "{source: text tree, truncated, total_returned, filtered?, coordinate_space:'points', hint}. Includes visible overlay windows (fixed bottom/floating bars) automatically."
        ),
        RPCMethodDef(
            name: "screenshot",
            description: "Capture a screenshot as base64 PNG. SECOND CHOICE after page_source — use when you need visual detail or an element is absent from the view tree. By default captures the WHOLE SCREEN (fast, ~0.4s). Pass bundle_id ONLY if you specifically want just one app's window cropped out (slower; time-bounded with a full-screen fallback). Image is in PIXELS; tap coordinates are in POINTS. Optional 'scale' controls output resolution (default 2, max 3, e.g. 1, 0.5).",
            params: [
                RPCParamDef(name: "scale", type: "number", required: false, description: "Output pixels-per-point (default 2, max 3; smaller = faster/less detail, e.g. 1 or 0.5)"),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "Crop to just this app's window (slower, time-bounded). OMIT for the default full-screen capture (fast) — the default is NOT scoped to the launched app."),
            ],
            returns: "Object: {data: base64 PNG, pixel_width, pixel_height, point_width, point_height, scale, scope:'screen'|'app', scoped_to?, hint}"
        ),
        RPCMethodDef(
            name: "tap",
            description: "Tap either by a stable 'ref' (from find_element/scroll_to_element — RECOMMENDED, re-resolves the live element and won't drift) OR by x,y coordinates in POINTS. If reading from a screenshot, convert: point = pixel / scale. Out-of-range coords return the valid range. Bottom tab bars sit just above the home-indicator safe area.",
            params: [
                RPCParamDef(name: "ref", type: "string", required: false, description: "Element ref from find_element/scroll_to_element (preferred over x,y)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "X in points (0..point_width) — required if no ref"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Y in points (0..point_height) — required if no ref"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "Use fast mode (bypasses quiescence waiting)"),
            ],
            returns: "{message, screen:{coordinate_space, point_width, point_height, scale}}"
        ),
        RPCMethodDef(
            name: "double_tap",
            description: "Double tap by a 'ref' (from find_element/scroll_to_element — preferred) OR by x,y in POINTS.",
            params: [
                RPCParamDef(name: "ref", type: "string", required: false, description: "Element ref (preferred over x,y)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "X in points — required if no ref"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Y in points — required if no ref"),
            ],
            returns: "{message, screen?}"
        ),
        RPCMethodDef(
            name: "long_press",
            description: "Long press by a 'ref' (from find_element/scroll_to_element — preferred) OR by x,y in POINTS.",
            params: [
                RPCParamDef(name: "ref", type: "string", required: false, description: "Element ref (preferred over x,y)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "X in points — required if no ref"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Y in points — required if no ref"),
                RPCParamDef(name: "duration", type: "number", required: false, description: "Press duration in seconds (default: 2.0)"),
            ],
            returns: "{message, screen?}"
        ),
        RPCMethodDef(
            name: "swipe",
            description: "Low-level swipe gesture. Do NOT use swipe to read through results/feeds — its default 100pt travel barely moves the page so you under-scroll and waste calls; use 'page' (one full screen, precise Page Down/Up, no overshoot) for reading, and 'scroll_to_element' to reach a known element. Reserve swipe for custom gestures (partial drags, horizontal carousels, pull-to-refresh). x,y OPTIONAL (default screen center). 'distance' = finger travel in points (default 100). 'velocity': 'fast'/'flick' adds iOS momentum (scrolls far, easy to overshoot), 'normal' (default), 'slow'/'precise' = exact drag.",
            params: [
                RPCParamDef(name: "x", type: "number", required: false, description: "Start X (default: screen center)"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Start Y (default: screen center)"),
                RPCParamDef(name: "direction", type: "string", required: false, description: "Finger direction: up/down/left/right (default: up). 'up' reveals content below."),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Finger travel in points (default: 100)"),
                RPCParamDef(name: "velocity", type: "string", required: false, description: "fast/flick (momentum, far), normal (default), slow/precise (exact, no momentum)"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "Use synthesized fast path (default true); set false for legacy XCUITest swipe"),
            ],
            returns: "{message, from:{x,y}, velocity, note}"
        ),
        RPCMethodDef(
            name: "page",
            description: "Scroll by one screenful — like Page Down / Page Up on a keyboard. This is the RECOMMENDED way to read through a long page: it's PRECISE (no momentum/overshoot), so you won't skip content the way swipe with velocity:'fast' does. Use {\"direction\":\"down\"} (default, reveal content below) or {\"direction\":\"up\"}; the aliases page_down / page_up force the direction. After paging, re-read with page_source or screenshot. To jump straight to a known element, prefer scroll_to_element.",
            params: [
                RPCParamDef(name: "direction", type: "string", required: false, description: "'down' (default, reveal below) or 'up'"),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Number of screenfuls (default 1; e.g. 0.5 = half a page, 2 = two pages)"),
            ],
            returns: "{message, screen}"
        ),
        RPCMethodDef(
            name: "scroll_to_element",
            description: "Auto-scroll until an element becomes visible, then return a stable 'ref' plus its tap point. Matching is EXACT by default (label == element_id, or accessibility id) to avoid hitting the wrong element — pass match:'contains' for a loose substring match. Narrow further with element_type. IMPORTANT: element_id must be the ACCESSIBILITY LABEL (from page_source), which may differ from on-screen text (e.g. a button showing '添加至购物袋' may have label '添加'). Prefer this over manual swipe loops.",
            params: [
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Exact accessibility label or identifier (see page_source)"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains' (substring)"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "Restrict to a type: button/textfield/label/image/cell/switch/icon"),
                RPCParamDef(name: "direction", type: "string", required: false, description: "Finger direction to scroll: up/down/left/right (default: up = reveal below)"),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Max swipe attempts (default: 12). Each swipe is ~40% of the screen (small, to avoid scrolling past short targets). Stops early if the end of the content is reached."),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "App to search; default = detected foreground app"),
            ],
            returns: "{found, swipes, ref, x, y, center_x, center_y, label, hint} — then tap by {ref}. Label matching ignores invisible formatting characters."
        ),
        RPCMethodDef(
            name: "scroll",
            description: "DEPRECATED — use 'swipe' instead (it supports velocity/momentum, custom distance, and start point), or 'scroll_to_element' to reach a specific element. This coarse full-screen scroll is kept only for compatibility.",
            params: [
                RPCParamDef(name: "direction", type: "string", required: false, description: "Direction: up/down/left/right (default: down)"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "type",
            description: "Type text into the focused input field. A text field must already have keyboard focus — tap a real textfield first (see 'searching_and_typing'). Type always runs, but if no keyboard could be confirmed the response includes a 'warning' (keyboard detection can't see all third-party keyboards, so this is advisory, not a failure) — if the text didn't land, re-focus the field and type again. Set clear:true to EMPTY the field before typing (replace its contents); set submit:true to append Return/Search so the field's action (search/go/send) fires. See searching_and_typing guidance for the full search flow.",
            params: [
                RPCParamDef(name: "text", type: "string", required: true, description: "Text to type (optional if clear:true — then it just empties the field)"),
                RPCParamDef(name: "clear", type: "boolean", required: false, description: "Empty the field (delete existing text) before typing. Use to REPLACE contents. The field must be focused first."),
                RPCParamDef(name: "submit", type: "boolean", required: false, description: "Append Return/Search to submit the field (recommended for search boxes)"),
                RPCParamDef(name: "x", type: "number", required: false, description: "Tap X to focus before typing"),
                RPCParamDef(name: "y", type: "number", required: false, description: "Tap Y to focus before typing"),
                RPCParamDef(name: "fast", type: "boolean", required: false, description: "Use fast mode"),
            ],
            returns: "{message, warning?} — warning present when a focused keyboard couldn't be confirmed"
        ),
        RPCMethodDef(
            name: "clear_text",
            description: "Empty the currently-focused text field (delete its existing contents) without typing anything new. The field must already have keyboard focus — tap a real textfield first. Equivalent to type{clear:true} with no text. Sends backspaces sized to the field's value (falls back to a generous default when the length can't be read). If no focused keyboard could be confirmed the response includes an advisory 'warning'.",
            params: [],
            returns: "{message, warning?} — warning present when a focused keyboard couldn't be confirmed"
        ),
        RPCMethodDef(
            name: "home",
            description: "Press the home button",
            params: [],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "lock",
            description: "Lock the screen",
            params: [],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "unlock",
            description: "Unlock the screen (may fail if passcode is set)",
            params: [],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "is_locked",
            description: "Check if the screen is locked",
            params: [],
            returns: "Lock state boolean"
        ),
        RPCMethodDef(
            name: "list_apps",
            description: "List installed apps with their bundle_id and name. NOTE: this relies on a private API that often returns an EMPTY list inside the XCTest sandbox — if count is 0, that's the sandbox limitation, not 'no apps'. Prefer resolve_app to get a bundle_id from an app name. Pass text to filter by name or bundle substring (case-insensitive). By default only user apps are returned; pass element_type:\"all\" to include system apps.",
            params: [
                RPCParamDef(name: "text", type: "string", required: false, description: "Filter by name/bundle_id substring"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "'all' to include system apps (default: user apps only)"),
            ],
            returns: "{count, apps:[{bundle_id, name}], hint}"
        ),
        RPCMethodDef(
            name: "resolve_app",
            description: "Resolve an app NAME/keyword to its bundle_id. PURPOSE: launch_app/activate_app need an exact bundle_id, but you usually only know the app's name — call resolve_app first to turn e.g. '大麦' into 'cn.damai.iphone', then pass that to launch_app. HOW IT WORKS: checks a built-in catalog of ~100 common apps first (instant, offline; returns source:'built-in'), and falls back to the App Store's iTunes Search API for anything else (returns full metadata). Note: resolving a bundle_id does NOT mean the app is installed on this device — launch_app will report if it isn't. (Alias: search_app.)",
            params: [
                RPCParamDef(name: "text", type: "string", required: true, description: "App name or keyword to resolve (e.g. '大麦', 'WeChat')"),
                RPCParamDef(name: "country", type: "string", required: false, description: "App Store country code for the fallback search (default: cn)"),
                RPCParamDef(name: "distance", type: "number", required: false, description: "Max results to return (default: 5, max 25)"),
            ],
            returns: "{count, term, source:'built-in'|'app_store', apps:[{name, bundle_id, developer?, category?, rating?, ...}], hint}"
        ),
        RPCMethodDef(
            name: "open_url",
            description: "Open a URL from the device — a custom app scheme, a universal/https link, or a deep link to a specific feature. Use this to jump into an app or a particular screen (e.g. 'weixin://' opens WeChat, 'alipays://platformapi/startapp?appId=…' opens an Alipay mini-program, 'https://…' opens in the default browser/handler, 'tel:10086' dials), or to jump BACK to a caller app via its callback URL (e.g. 'minis://done?status=ok'). For simply bringing an app to the front by identity, prefer launch_app with a bundle_id. URL-encode query values as needed.",
            params: [
                RPCParamDef(name: "url", type: "string", required: true, description: "The URL to open (scheme://… or https://…)"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "launch_app",
            description: "Open an app by bundle identifier (non-blocking, via LSApplicationWorkspace). If you don't know the bundle_id, use resolve_app to find it (e.g. '大麦' → cn.damai.iphone). The opened app becomes the STICKY TARGET for subsequent UI actions (see app_binding). NOTE: the app is still launching/rendering when this returns — wait 2-3s (call wait) before page_source, or you'll match splash/placeholder elements.",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier (from resolve_app)"),
            ],
            returns: "{message, bound_app, advice}"
        ),
        RPCMethodDef(
            name: "activate_app",
            description: "Bring an already-installed app to the foreground and make it the STICKY TARGET (see app_binding). Like launch_app but uses XCUIApplication.activate. Errors if the app isn't installed / can't be activated.",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "terminate_app",
            description: "Terminate a running app",
            params: [
                RPCParamDef(name: "bundle_id", type: "string", required: true, description: "App bundle identifier"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "find_element",
            description: "Find an on-screen element by its accessibility LABEL (exact by default) or identifier, and get a stable 'ref' + frame back. Matching order: exact label → accessibility id → (if match:'contains') substring; returns the first HITTABLE match. Use match:'contains' for loose matching, element_type to disambiguate. If the element needs scrolling to appear, use scroll_to_element instead. The returned ref is the reliable way to then tap/double_tap/long_press it.",
            params: [
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label (from page_source) or identifier"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains' (substring)"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "button/textfield/label/image/cell/switch/icon/any"),
                RPCParamDef(name: "bundle_id", type: "string", required: false, description: "App to search; default = detected foreground app"),
            ],
            returns: "{exists, hittable, ref, element_type, is_text_input, x, y, width, height, center_x, center_y, label, value, note?} — element_type/is_text_input tell you if you matched a real input field vs a button; note flags the 'fake search bar' case. Then act by {ref}."
        ),
        RPCMethodDef(
            name: "tap_element",
            description: "Convenience: find an element by label/id and tap it in one call. Equivalent to find_element + tap{ref}. Prefer find_element when you also need the frame or want to double_tap/long_press.",
            params: [
                RPCParamDef(name: "element_id", type: "string", required: true, description: "Accessibility label or identifier"),
                RPCParamDef(name: "match", type: "string", required: false, description: "'exact' (default) or 'contains'"),
                RPCParamDef(name: "element_type", type: "string", required: false, description: "Element type filter"),
            ],
            returns: "{message}"
        ),
        RPCMethodDef(
            name: "drag",
            description: "Drag between two points. Endpoints may be coordinates (from_x/from_y/to_x/to_y in POINTS) OR element refs (from_ref/to_ref, which resolve to the element center). Use for reordering/sliders; for a simple scroll flick use swipe.",
            params: [
                RPCParamDef(name: "from_ref", type: "string", required: false, description: "Start element ref (alternative to from_x/from_y)"),
                RPCParamDef(name: "to_ref", type: "string", required: false, description: "End element ref (alternative to to_x/to_y)"),
                RPCParamDef(name: "from_x", type: "number", required: false, description: "Start X (points)"),
                RPCParamDef(name: "from_y", type: "number", required: false, description: "Start Y (points)"),
                RPCParamDef(name: "to_x", type: "number", required: false, description: "End X (points)"),
                RPCParamDef(name: "to_y", type: "number", required: false, description: "End Y (points)"),
                RPCParamDef(name: "duration", type: "number", required: false, description: "Drag duration in seconds (default: 0.5)"),
            ],
            returns: "{message, screen}"
        ),
        RPCMethodDef(
            name: "wait",
            description: "Pause for a fixed duration. Use SPARINGLY — most waits are wasted latency. tap/type/swipe/page/scroll already block on UI quiescence before they return, and page_source reads whatever is currently settled, so after an interaction you can read/act DIRECTLY without waiting. Legit uses: (a) 2-3s once after a COLD launch_app while the app renders; (b) a known async delay (search results loading over the network, a video). If a page_source comes back mid-transition (splash/placeholder/empty), wait ~1s and re-read REACTIVELY — don't pre-emptively sleep after every step.",
            params: [
                RPCParamDef(name: "duration", type: "number", required: false, description: "Duration in seconds (default: 1.0)"),
            ],
            returns: "{message}"
        ),
    ]

    static func generateJSONSchema() -> [[String: Any]] {
        methods.map { m in
            var dict: [String: Any] = [
                "name": m.name,
                "description": m.description,
                "returns": m.returns,
            ]
            dict["params"] = m.params.map { p in
                [
                    "name": p.name,
                    "type": p.type,
                    "required": p.required,
                    "description": p.description,
                ] as [String: Any]
            }
            return dict
        }
    }

    /// A self-describing document for models: top-level guidance + methods.
    /// Returned from GET /schema and GET / (Accept: application/json).
    /// Semantic server version — bump on every functional change. 1.2.0 is the
    /// release that added the encrypted auth channel plus the docs/Skill,
    /// clear-text, page-source, and reliability improvements. Single source of
    /// truth for /schema AND device_info.
    static let serverVersion = "1.2.3"

    /// Server capability/protocol version. v1 = Bearer-token auth over /auth +
    /// /rpc. Bump when the wire capabilities change so clients can auto-detect.
    static let protocolVersion = 1

    /// Capability tags a client can feature-detect against, from ONE device_info
    /// call (no separate /schema fetch needed). Keep in sync with what the server
    /// actually implements.
    static let capabilityTags: [String] = [
        "bearer_auth",         // /auth + /rpc (Bearer token)
        "basic_auth",          // Also HTTP Basic + ?token=<token> for player/browser URLs
        "video_stream",        // GET /stream (H.264-in-MPEG-TS live screen)
        "remote_ui",           // GET /remote (browser control page)
        "page_source_filter",  // page_source{filter:{...}}
        "max_depth",           // page_source{max_depth}
        "find_element_ref",    // find_element → ref; tap{ref}
        "scroll_to_element",   // scroll_to_element → ref
        "clear_text",          // clear_text + type{clear:true}
        "open_url",            // open_url deep links
        "resolve_app",         // resolve_app name → bundle_id
        "page",                // page{direction} precise paging
        "stop_server",         // config{stop_server:true}
        "logs_history",        // GET /logs/history (persisted logs)
    ]

    static func generateSchemaDocument() -> [String: Any] {
        [
            "protocol": "JSON-RPC 2.0",
            "server_version": serverVersion,
            // Capability version — clients negotiate against this.
            "protocol_version": protocolVersion,
            // Feature-detection tags (same list device_info returns, so a client
            // can negotiate from either one).
            "capability_tags": capabilityTags,
            "endpoints": [
                "skill": "GET /skill — START HERE. The operating manual in Skill (Markdown) format; read it ONCE to learn the fast-path workflow and best practices, then treat iCTRL as a Skill.",
                "auth": "POST /auth  {client_name} → {token}. IMPORTANT: this BLOCKS until the device user manually taps Allow/Deny on an on-screen prompt — use a long client timeout (at least 60s) and do NOT retry early; a retry queues another prompt. Returns 403 if denied.",
                "rpc": "POST /rpc   {jsonrpc, method, params, id}  (Authorization: Bearer <token>)",
                "stream": "GET /stream[.ts]  live H.264-in-MPEG-TS screen video (~2 fps, ?fps=N to change). Auth via Bearer, HTTP Basic, or ?token=<token> so a browser/player can open the URL directly. Play in VLC: `vlc http://<token>@<host>:8200/stream`. One shared encoder fans out to all clients; encoding stops when the last client disconnects.",
                "remote": "GET /remote  browser control page (shadcn-styled): plays /stream in <video> (via mpegts.js) and drives the device with tap/swipe/scroll/keyboard + a side panel of buttons. Open `http://<host>:8200/remote?token=<token>` to auto-connect.",
                "logs": "GET /logs   plain-text recent logs (current process, in-memory). REQUIRES Authorization: Bearer <token>. Sensitive values are redacted",
                "logs_files": "GET /logs/files   list persisted daily log files (survive crashes/restarts)",
                "logs_history": "GET /logs/history?date=YYYY-MM-DD   dump a persisted day's log (redacted). Use this to recover logs from BEFORE a crash — /logs only holds the current process's memory",
                "schema": "GET /schema  this document",
            ],
            "guidance": [
                "authorization":
                    "Before any /rpc call you need a token from POST /auth {client_name}. " +
                    "Authorization REQUIRES the device user to manually approve your request on an on-screen prompt, " +
                    "so the /auth request can take a while to return — set a client-side timeout of AT LEAST 60 seconds " +
                    "and wait patiently; do not retry early (each retry pops another prompt). " +
                    "On approval you get a token (valid 30 days, survives app restarts); on denial you get HTTP 403. " +
                    "Send the token as 'Authorization: Bearer <token>' on every /rpc call. " +
                    "If the service restarts (see 'connection_reliability'), re-run /auth to get a fresh token before continuing.",
                "client_timeouts":
                    "Set generous client timeouts for /rpc: at least 30s, ideally 60-120s. " +
                    "/schema and /logs are static and reply instantly, but /rpc drives the real device — a cold app " +
                    "launch or heavy page can make a single call take many seconds. " +
                    "CRITICAL: a client-side curl timeout does NOT mean the action failed — the device keeps executing " +
                    "and the call usually completes. Before retrying a timed-out /rpc, GET /logs and look for a " +
                    "'⏱ ✓ <method>' entry — if it's there, the action already succeeded and retrying would DOUBLE it " +
                    "(e.g. a tap fires twice). Only retry if /logs shows no success and no in-flight entry.",
                "connection_reliability":
                    "The service runs inside an XCUITest process on the phone and can occasionally drop (iOS backgrounding " +
                    "limits, or a stuck long-running call). Treat 8200 as possibly-transient: " +
                    "(1) Before a session, probe with a SHORT timeout: GET /schema (1-2s) — 200 means ready. " +
                    "(2) If the app was just woken via the ictrl:// URL scheme, note the returned 'opened' flag is UNRELIABLE " +
                    "(it only means the URL was handed to the system, NOT that the server is up) — always confirm by polling " +
                    "GET /schema for a few seconds. " +
                    "(3) If /rpc starts failing AND /logs is also unreachable, the service died — re-wake via ictrl:// and " +
                    "poll /schema until it returns 200, then re-/auth for a fresh token. " +
                    "(4) Space out ictrl:// re-wakes by a couple seconds; rapid repeats may be throttled. " +
                    "(5) CHEAP RECOVERY: don't restart the task from scratch. The resolved bundle_id is stable — REUSE it, do NOT call resolve_app again. The token lasts 30 days and persists across restarts, so re-/auth only if a call actually returns 401. If you know a deep link back to where you were (open_url), use it instead of re-navigating from the app's home screen.",
                "searching_and_typing": [
                    "Searching inside an app is the #1 place automation goes wrong. Follow this sequence:",
                    "DON'T BLIND-WAIT between steps. tap/type/swipe/page already block on UI quiescence before returning, so after them you can page_source/find_element DIRECTLY — no wait call. The ONLY routine wait is after a COLD launch_app (2-3s, the app is still rendering). If a read comes back mid-transition (splash/placeholder/empty), THEN wait ~1s and re-read — reactively, not by default. Blind 2-3s sleeps after every tap just add latency.",
                    "1. launch_app, then wait 2-3s ONCE (cold render). If you opened via open_url to a specific screen, often no wait is needed.",
                    "2. Find the search ENTRY by its visible label (whatever the app's language). It's often a Button/StaticText that opens a search PAGE, not a real input — is_text_input:false confirms it's an entry, not the field. find_element{element_id:'<label>'} → tap{ref}.",
                    "3. tap{ref} that entry (use the ref from step 2, not coordinates). No wait — tap already settled; go straight to step 4.",
                    "4. Locate the REAL input: find_element{element_type:\"textfield\"} (or searchField), confirm is_text_input:true, then tap{ref} to focus. (The keyboard comes up as part of that tap.)",
                    "5. type{text:\"…\", submit:true}. If type returns a 'no keyboard/focus' warning, re-focus the textfield (step 4) and retry — don't assume it went in.",
                    "6. Read results with page_source directly (no wait) — only if it's still loading do you wait ~1s and re-read.",
                    "Key trap: type() into an unfocused field silently loses the text and submit:true then searches an empty/garbage query. type() returns a 'warning' when it can't confirm a focused keyboard — heed it and re-focus if needed.",
                    "To REPLACE existing text, use type{clear:true, text:\"…\"} (empties first) or clear_text; tap the field to focus before clearing.",
                ],
                "app_binding":
                    "After you open an app with launch_app/activate_app it becomes the STICKY TARGET (see 'bound_app' " +
                    "in the launch_app response). INTERACTION methods (tap, double_tap, long_press, tap_element, " +
                    "swipe, scroll, scroll_to_element, drag, page) re-focus the bound app automatically if the " +
                    "foreground drifted — the response then carries an 'app_note' saying it was re-focused — so " +
                    "launch an app then 'tap …' always acts on THAT app even if another app came to the front. " +
                    "READ-ONLY methods (page_source, screenshot, find_element) do NOT re-activate the bound app: " +
                    "they read whatever is CURRENTLY in the foreground, because force-activating just to read can " +
                    "stall on launch/transition animations. If the bound app was pushed to the background and you " +
                    "want to read IT specifically, either run one interaction first (which re-focuses it) or pass the " +
                    "app's explicit bundle_id to the read call (e.g. page_source{bundle_id:'<the bound app>'}). " +
                    "For interaction methods, two situations abort with a clear error instead of doing the wrong thing: " +
                    "(1) the bound app has CRASHED/EXITED (state notRunning) → error tells you to launch_app again; " +
                    "(2) a SYSTEM ALERT/permission dialog is covering the app → error tells you to read it via " +
                    "page_source{bundle_id:'com.apple.springboard'} and tap its button first. " +
                    "To act on a DIFFERENT app for one call, pass an explicit bundle_id (does not change the sticky " +
                    "target). Opening another app moves the target; terminate_app on the target clears it.",
                "opening_apps_and_urls": [
                    "Don't guess bundle IDs. To open an app by name:",
                    "1. resolve_app{text:'携程'} → resolves a name/keyword to a bundle_id via a built-in catalog, " +
                    "falling back to the iTunes Search API (source field says which). Returns candidates with bundle_id + name.",
                    "2. launch_app{bundle_id:<resolved>} → opens it and binds it as the sticky target.",
                    "list_apps returns the bundle IDs actually INSTALLED on this device — use it to confirm an app is present.",
                    "open_url{url:'scheme://…'} opens an app URL scheme / deep link (often faster than launch_app and can jump " +
                    "straight to a feature). Use it when you already know the app's scheme; use launch_app when you just want the app's home.",
                ],
                "scrolling_and_paging":
                    "Two ways to move a scroll view: swipe/scroll (a gesture — fast, has momentum, can overshoot) and " +
                    "page (a precise one-screen step, ~85% of the screen, NO momentum — best for reading long content " +
                    "predictably). page{direction:'down', pages:N} advances N screens. Prefer page when reading a feed/" +
                    "detail page screen-by-screen; use scroll_to_element when you're hunting a specific labeled element.",
                "stopping_the_service":
                    "config{stop_server:true} shuts the service down (it replies first, then stops listening ~1s later). " +
                    "Tokens persist, so after the runner is relaunched you can reconnect WITHOUT re-authorizing. Only do " +
                    "this when you intend to end automation — there is no remote start, the runner must be relaunched on-device.",
                "inspecting_ui":
                    "PREFER page_source (the accessibility/view hierarchy as text) to understand layout — " +
                    "it gives element types, labels, identifiers, and exact frames in POINTS, is far smaller " +
                    "than an image, and needs no pixel→point conversion. Use screenshot only as a SECOND choice: " +
                    "when an element is missing from the tree or you need visual detail. To go even lighter, " +
                    "request a smaller screenshot with scale (e.g. 1 or 0.5).",
                "locating_elements_decision_tree": [
                    "Pick the locate method by situation — each returns a stable 'ref' you then act on:",
                    "0. You already know the label of an on-screen control (search bar, a named button) → skip page_source, go STRAIGHT to find_element{element_id:<label>} → tap{ref}. Don't read the tree just to compute coordinates.",
                    "1. Element has a clear text/label AND is on screen → find_element{element_id:<label>} → tap{ref}. Fastest, precise.",
                    "2. Element is off-screen (need to scroll to it) → scroll_to_element{element_id:<label>} — it scrolls then returns the ref in one call. Don't hand-roll swipe loops.",
                    "3. App exposes accessibility identifiers (look for 'identifier:' in page_source, e.g. big apps use them for their own UI tests) → use that id as element_id — the most stable key.",
                    "4. The on-screen text ≠ accessibility label (common!), or label is truncated → read the EXACT label from page_source first, or use match:'contains'.",
                    "5. Pure icon / image / canvas with no useful label (games, webviews, custom-drawn UI) → screenshot, find it visually, tap by COORDINATE (pixel/scale). This is the fallback, not the default.",
                    "6. Multiple elements share a label → add element_type (button/cell/…) to disambiguate; the matcher returns the first HITTABLE one.",
                    "Prefer ref over coordinates whenever you have one: a ref re-resolves the live element and won't drift if the layout shifts; a coordinate is a fixed point that breaks after any scroll/animation.",
                ],
                "coordinate_space":
                    "tap, double_tap, long_press, swipe, drag and type(x,y) all use POINTS, not pixels. " +
                    "page_source frames are already in points. Screenshots are PIXELS: point = pixel / scale. " +
                    "Get scale and the valid point range from device_info (point_width/point_height).",
                "recommended_flow":
                    "1) call device_info once to learn point_width/point_height/scale. " +
                    "2) open the app you need: resolve_app{text:<name>} → launch_app{bundle_id} (or open_url for a deep link). " +
                    "3) call page_source to read the current layout (types, labels, ids, frames in points). " +
                    "4) locate the target: find_element (on screen) or scroll_to_element (needs scrolling) → get a ref. " +
                    "5) act by ref: tap/double_tap/long_press{ref}, or drag{from_ref,to_ref}; page{direction} to read long content. " +
                    "6) only fall back to screenshot + coordinate tap when the element has no usable label. " +
                    "7) re-check with page_source (or screenshot) to verify the result.",
                "common_pitfalls": [
                    "Reaching for screenshot first when page_source + find_element would locate the element more precisely and cheaply.",
                    "Using a coordinate when a ref is available — the coordinate breaks after any scroll/animation; a ref re-resolves the live element.",
                    "Passing raw pixel coordinates to tap → taps land off-target or out of bounds. Convert pixel/scale first.",
                    "Bottom tab bars/buttons live just above the home-indicator safe area; if a tap seems ignored, aim slightly higher (smaller y).",
                    "Searching by the ON-SCREEN text when the accessibility label differs (e.g. a button reads '添加至购物袋' but its label is '添加') — read the exact label from page_source, or use match:'contains'.",
                    "type requires an input field to already have keyboard focus — tap the field first (or pass x,y). To run a search, use type{submit:true} instead of hunting for the keyboard's Search key.",
                    "unlock only wakes the screen; a passcode-locked device must be unlocked by the user.",
                ],
            ],
            "methods": generateJSONSchema(),
        ]
    }

    static func generateHTMLDoc() -> String {
        var html = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>iCTRL API</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, system-ui, sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 20px; }
        h1 { font-size: 28px; font-weight: 700; margin-bottom: 8px; }
        .subtitle { color: #86868b; margin-bottom: 24px; }
        .endpoint { background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 12px; }
        .endpoint-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
        .method-name { font-size: 17px; font-weight: 600; font-family: SF Mono, monospace; color: #0071e3; }
        .desc { color: #6e6e73; font-size: 14px; margin-bottom: 8px; }
        .params { font-size: 13px; }
        .param { display: flex; gap: 8px; padding: 4px 0; border-top: 1px solid #f5f5f7; }
        .param-name { font-family: SF Mono, monospace; font-weight: 500; min-width: 100px; }
        .param-type { color: #86868b; min-width: 60px; }
        .param-req { color: #bf4040; font-size: 11px; }
        .section { margin-top: 24px; margin-bottom: 12px; font-size: 20px; font-weight: 600; }
        .info { background: #fff; border-radius: 12px; padding: 16px; margin-bottom: 12px; }
        code { background: #f5f5f7; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
        pre { background: #1d1d1f; color: #f5f5f7; padding: 12px; border-radius: 8px; font-size: 13px; overflow-x: auto; margin-top: 8px; }
        </style>
        </head><body>
        <h1>iCTRL API</h1>
        <p class="subtitle">JSON-RPC 2.0 &middot; iOS Automation Server</p>

        <div class="info">
        <p><strong>RPC Endpoint:</strong> <code>POST /rpc</code></p>
        <p style="margin-top:4px"><strong>Auth Endpoint:</strong> <code>POST /auth</code> — <code>{client_name}</code> → <code>{token}</code></p>
        <p style="margin-top:8px">All <code>/rpc</code> calls require the <code>Authorization: Bearer &lt;token&gt;</code> header.</p>
        <pre>{"jsonrpc": "2.0", "method": "tap", "params": {"x": 100, "y": 200}, "id": 1}</pre>
        </div>

        <div class="info" style="border-left:4px solid #ff9500">
        <p><strong>⏳ First, get a token — the user must approve it.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        <code>POST /auth {client_name}</code> shows an <em>Allow / Deny</em> prompt on the device and BLOCKS until the user responds.
        Use a client timeout of <strong>at least 60 seconds</strong> and wait — do not retry early (each retry pops another prompt).
        On approval you receive a token (valid 30 days); on denial, HTTP 403.
        </p>
        </div>

        <div class="info" style="border-left:4px solid #5856d6">
        <p><strong>🔎 Version &amp; capabilities.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        <code>device_info</code> (and <code>/schema</code>) report <code>server_version</code>, <code>protocol_version</code>
        and a <code>capabilities</code> array — feature-detect from ONE call and don't assume a method exists on an older
        <code>server_version</code>.
        </p>
        </div>

        <div class="info" style="border-left:4px solid #ff3b30">
        <p><strong>⚠️ Reliability &amp; timeouts — read before automating.</strong></p>
        <ul style="margin:6px 0 0 18px;color:#6e6e73;font-size:14px;line-height:1.6">
        <li><strong>Use long <code>/rpc</code> timeouts (≥30s, ideally 60–120s).</strong> <code>/schema</code> and <code>/logs</code> reply instantly, but <code>/rpc</code> drives the real device and a call can take seconds.</li>
        <li><strong>A client timeout ≠ failure.</strong> The device keeps executing. Before retrying, <code>GET /logs</code> and look for <code>⏱ ✓ &lt;method&gt;</code> — if present, it already succeeded and retrying would double the action.</li>
        <li><strong>Probe readiness with <code>GET /schema</code> (short timeout).</strong> If you woke the service via the <code>ictrl://</code> URL scheme, the <code>opened</code> flag is NOT proof the server is up — the runner cold-starts and needs a few seconds to bind :8200. Poll <code>/schema</code> until it returns 200.</li>
        <li><strong>If <code>/rpc</code> and <code>/logs</code> both go unreachable</strong>, the runner process died — re-wake via <code>ictrl://</code>, poll <code>/schema</code> until ready, then re-run <code>/auth</code> for a fresh token.</li>
        </ul>
        </div>

        <div class="info" style="border-left:4px solid #34c759">
        <p><strong>👁 Inspect the UI with <code>page_source</code> first.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        <code>page_source</code> returns the view hierarchy as text (types, labels, identifiers, and frames
        already in <em>points</em>) — smaller, faster and more precise than an image. Use <code>screenshot</code>
        only when an element is missing from the tree or you need visual detail (and you can shrink it with <code>scale</code>).
        </p>
        <p style="margin-top:8px;color:#6e6e73;font-size:14px">
        Rich pages can be big and the first call after a launch can be slow. <strong>Scope it:</strong>
        <code>page_source({"filter":{"label":"&lt;substring&gt;"}})</code> returns only matching nodes + ancestors;
        <code>{"max_depth":3}</code> gives just the top structure; <code>{"max_elements":200}</code> caps the count.
        A 500-node hard cap applies by default (<code>truncated:true</code> when hit).
        </p>
        </div>

        <div class="info" style="border-left:4px solid #0071e3">
        <p><strong>⚠️ Coordinates use POINTS, not pixels.</strong></p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        Screenshots come back in <em>pixels</em>; <code>tap</code>/<code>swipe</code>/<code>drag</code> take <em>points</em>.
        Convert: <code>point = pixel / scale</code>. Get <code>scale</code> and the valid range
        (<code>point_width</code> × <code>point_height</code>) from <code>device_info</code>.
        </p>
        <p style="margin-top:6px;color:#6e6e73;font-size:14px">
        Recommended flow: <code>device_info</code> → <code>resolve_app</code>/<code>launch_app</code> → <code>page_source</code> → tap frame center → verify.
        Fetch <code>GET /schema</code> for full machine-readable guidance (app binding, searching/typing, reliability…).
        </p>
        </div>

        <div class="info">
        <p><strong>Diagnostics &amp; logs (Bearer token required, redacted):</strong></p>
        <ul style="margin:6px 0 0 18px;color:#6e6e73;font-size:14px;line-height:1.6">
        <li><code>GET /logs</code> — recent in-memory logs for the current process (includes <code>⏱ ✓ &lt;method&gt; &lt;ms&gt;</code> timings).</li>
        <li><code>GET /logs/files</code> — list persisted daily log files (survive crashes/restarts).</li>
        <li><code>GET /logs/history?date=YYYY-MM-DD</code> — read a persisted day's log. Use this to recover logs from BEFORE a crash.</li>
        <li><code>GET /schema</code> — this document, as JSON.</li>
        </ul>
        <p style="margin-top:8px;color:#6e6e73;font-size:14px">Stop the service remotely with <code>config {"stop_server": true}</code> — tokens persist, so relaunching the runner needs no re-auth.</p>
        </div>

        <p class="section">Methods (\(methods.count))</p>
        """

        for m in methods {
            html += """
            <div class="endpoint">
            <div class="endpoint-header"><span class="method-name">\(m.name)</span></div>
            <p class="desc">\(m.description)</p>
            """
            if !m.params.isEmpty {
                html += "<div class=\"params\">"
                for p in m.params {
                    let req = p.required ? "<span class=\"param-req\">required</span>" : ""
                    html += """
                    <div class="param">
                    <span class="param-name">\(p.name)</span>
                    <span class="param-type">\(p.type)</span>
                    <span>\(p.description) \(req)</span>
                    </div>
                    """
                }
                html += "</div>"
            }
            html += "</div>"
        }

        html += "</body></html>"
        return html
    }
}

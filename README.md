### KodaMicroHttp

Wrapper for libmicrohttpd.

This server automatically uses a thread pool of your core count * 2.

Also has automatic thread context management and temporary allocator freeing after each request has been processed.

### EXAMPLE CODE

```jai
main :: () {
    server := create_server(4000);
    defer destroy_server(server);

    server.extra_headers = .[
        .["Access-Control-Allow-Origin", "*"],
        .["Access-Control-Allow-Methods", "GET, POST, OPTIONS"],
        .["Access-Control-Allow-Headers", "Content-Type"],
    ];

    handle(server, .Get, "/frontpage", (request: *HttpRequest, response: *HttpResponse) -> HttpResult {
        data: FrontpageData;
        data.hero = "narrow_one/banner.png";
        data.recommended[0] = "monster_adventure/cover.png";
        data.recommended[1] = "shell_shockers/cover.png";
        data.recommended[2] = "evade/cover.png";
        data.recommended[3] = "bloxd_io/cover.png";
        data.recommended[4] = "rocket_bot_royale/cover.png";

        json_string := json_write(data, write_extra_null = true);
        return reply(response, 200, .[.["Content-Type", "application/json"]], json_string, .Allocated);
    });

    handle(server, .Post, "/frontpage", (request: *HttpRequest, response: *HttpResponse) -> HttpResult {
        return reply(response, 200, .[.["Content-Type", "application/json"]], "{\"get\": false}\0");
    });

    handle(server, .Fallback, "*", (request: *HttpRequest, response: *HttpResponse) -> HttpResult {
        return reply(response, 404, .[], "");
    });

    server_listen(server);

    server_stop(server);
}

FrontpageData :: struct {
    hero: string;
    recommended: [5] string;
}
```
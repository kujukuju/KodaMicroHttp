## KodaMicroHttp

Simplicity wrapper for libmicrohttpd.

This server automatically uses a thread pool of your core count.

Also has automatic thread context management and temporary allocator freeing after each request has been processed.

This server also automatically handles post data accumulation before running the handler.

Each request allocates a bit of memory and frees when the request is finished, because post requests can sometimes take multiple iterations to complete. The default allocator is based on your context when you create each server. The temporary allocators are default. You could make every request use the temporary allocator, but if you're uploading large files and the post processor has to run multiple times, I'm not sure if this is synchronous. If it does happen to be a guaranteed synchronous operation you could use the temporary allocator as your default allocator for all requests, but large files might fail.

There seems to be some cold starting latency issues with libmicrohttpd when running on windows or WSL. These issues don't seem to exist when running natively on linux.

---

## TIPS

If you're doing a lot of processing before you respond to requests it might be optimal to add HEAD specific handlers to just return the header data. Otherwise, this will be handled automatically and the body data discarded.

---

## EXAMPLE CODE

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
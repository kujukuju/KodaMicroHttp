
HttpServer :: struct {
    port: u16;
    timeout_seconds: int;
    thread_count: int;
    daemon: *MHD_Daemon;
    handlers: [http_method_count] HttpHandler;
    // optional_handlers: [http_method_count] [..] HttpHandlerWithOptions;
    fallback_handlers: [http_method_count] InternalRequestHandler;
    // fallback_handlers_with_options: [http_method_count] RequestHandlerWithOptions;
    extra_headers: [] [2] *u8;
    // once this is flipped to true we'll no longer lock the mutex since the table will never again change
    threads_propagated: bool;
    thread_contexts_mutex: Mutex;
    thread_contexts: Table(u64, Context);
    allocator: Allocator;
}

// RequestHandlerWithOptions :: struct {
//     callback: *void;
//     callback_type: Type;
// }

HttpHandler :: struct {
    part: string;
    children: [..] HttpHandler;
    optional: *HttpHandler;
    callback: InternalRequestHandler;
}

// HttpHandlerWithOptions :: struct {
//     part: string;
//     children: [..] HttpHandlerWithOptions;
//     fallback: HttpHandlerWithOptions;
//     callback: RequestHandlerWithOptions;
// }

HttpFormEntry :: struct {
    name: string;
    filename: string;
    value: string;
}

HttpRequest :: struct {
    server: *HttpServer;
    form_data: [..] HttpFormEntry;
    post_processor: *MHD_PostProcessor;
    content_type: string;
    error: bool;
}

HttpResponse :: struct {
    server: *HttpServer;
    connection: *MHD_Connection;
}

HttpResult :: struct {
    result: MHD_Result;
}

HttpMethod :: enum u16 {
    Connect;
    Delete;
    Get;
    Head;
    Options;
    Patch;
    Post;
    Put;
    Trace;
    Fallback;
}

HttpMemoryMode :: enum u16 {
    // do nothing with the memory when done
    Static;
    // free the memory when done
    Allocated;
    // copy and manage the memory entirely
    Copy;
}

// RequestHandler :: #type (request: *HttpRequest, response: *HttpResponse) -> HttpResult;
InternalRequestHandler :: #type (request: *HttpRequest, response: *HttpResponse, optionals: [] string) -> HttpResult;
// RequestHandlerWithOptions :: #type (request: *HttpRequest, response: *HttpResponse, path_fields: ..string) -> HttpResult;

create_server :: (port: u16, timeout_seconds: int = 60, thread_count: int = core_count) -> *HttpServer {
    server := New(HttpServer);
    server.port = port;
    server.timeout_seconds = timeout_seconds;
    server.thread_count = thread_count;
    server.allocator = context.allocator;

    init(*server.thread_contexts_mutex);

    return server;
}

destroy_server :: (server: *HttpServer) {
    for handler: server.handlers {
        destroy_handler(handler);
    }
    destroy(*server.thread_contexts_mutex);
    // not sure if the daemon has to be freed, I don't think so
    free(server);
}

server_listen :: (server: *HttpServer) {
    if !server_listen_async(server) {
        return;
    }

    print("Listening on port %...\n", server.port);

    semaphore: Semaphore;
    init(*semaphore);
    wait_for(*semaphore);
}

server_listen_async :: (server: *HttpServer) -> bool {
    init(*server.thread_contexts, server.thread_count);

    server.daemon = MHD_start_daemon(
        cast(u32) (MHD_FLAG.MHD_USE_INTERNAL_POLLING_THREAD | .USE_AUTO),
        server.port,
        null,
        null,
        server_respond,
        cast(*void) server,
        MHD_OPTION.MHD_OPTION_NOTIFY_COMPLETED, server_completed, null,
        MHD_OPTION.MHD_OPTION_CONNECTION_MEMORY_LIMIT, cast(u64) (256 * 1024),
        MHD_OPTION.MHD_OPTION_THREAD_POOL_SIZE, server.thread_count,
        MHD_OPTION.MHD_OPTION_CONNECTION_TIMEOUT, server.timeout_seconds,
        MHD_OPTION.MHD_OPTION_END);

    return server.daemon != null;
}

server_stop :: (server: *HttpServer) {
    print("Stopping server on port %.\n", server.port);

    MHD_stop_daemon(server.daemon);

    for thread_context, thread_id: server.thread_contexts {
        free_thread_context(server, thread_context);
    }
    deinit(*server.thread_contexts);
    server.threads_propagated = false;
}

// this method accepts your handler, and it bakes it inside a compile time method that automatically unwraps an array
handle :: (server: *HttpServer, method: HttpMethod, $path: string, $handler: $T) {
    #run assert(starts_with(path, "/") || starts_with(path, "*"), "Your handler path must start with either \"/\" or \"*\".");
    #run assert(!starts_with(path, "*") || path.count == 1, "If your handler path starts with \"*\" it cannot contain anything else.");

    has_optional_arguments :: #run (cast(*Type_Info_Procedure) type_info(T)).argument_types.count > 2;

    #if has_optional_arguments {
        // #run assert((cast(*Type_Info_Procedure) type_info(T)).argument_types.count - 2 == get_optional_count(path), "If you have optional arguments you must have as many as optional path parts.");
        #run assert((cast(*Type_Info_Procedure) type_info(T)).argument_types.count - 2 <= get_optional_count(path), "You cannot have more optional arguments than optional path parts.");
        #run assert(() -> bool {
            procedure_info := cast(*Type_Info_Procedure) type_info(T);
            for i: 2..procedure_info.argument_types.count - 1 {
                if procedure_info.argument_types[i].type != .STRING {
                    return false;
                }
            }

            return true;
        }(), "You cannot have optional arguments that are non-strings.");

        #insert #run () -> string {
            procedure_info := cast(*Type_Info_Procedure) type_info(T);
            handler_optional_count := procedure_info.argument_types.count - 2;

            // we're guaranteed to pass in the correct number of optionals because the path is compile time and calling this is handled internally
            builder: String_Builder;
            append(*builder, "internal_handler :: (request: *HttpRequest, response: *HttpResponse, optionals: [] string) -> HttpResult {\n");
            for i: 0..handler_optional_count - 1 {
                append(*builder, tprint("optional% := optionals[%];\n", i, i));
            }

            append(*builder, "return inline handler(request, response, ");
            for i: 0..handler_optional_count - 1 {
                append(*builder, tprint("optional%", i, i));
                if i < handler_optional_count - 1 {
                    append(*builder, ", ");
                }
                append(*builder, ");\n");
            }
            append(*builder, "}\n");

            return builder_to_string(*builder);
        }();
    } else {
        internal_handler :: (request: *HttpRequest, response: *HttpResponse, optionals: [] string) -> HttpResult {
            return inline handler(request, response);
        }
    }

    #if path == "*" {
        assert(!server.fallback_handlers[cast(int) method], "You cannot override an existing handler callback.");
        server.fallback_handlers[cast(int) method] = internal_handler;
    } else {
        final_handler := add_handler(*server.handlers[cast(int) method], path);
        assert(!final_handler.callback, "You cannot override an existing handler callback.");
        final_handler.callback = internal_handler;
    }
}

// handle :: (server: *HttpServer, method: HttpMethod, $path: string, $handler: $T) #modify {
//     return (cast(*Type_Info_Procedure) type_info(T)).argument_types.count > 2;
// } {
//     #run assert(starts_with(path, "/") || starts_with(path, "*"), "Your handler path must start with either \"/\" or \"*\".");
//     #run assert((cast(*Type_Info_Procedure) type_info(T)).argument_types.count - 2 == get_optional_count(path), "You must have the same number of optional arguments as path options.");
//     #run assert(() -> bool {
//         procedure_info := cast(*Type_Info_Procedure) type_info(T);
//         for i: 2..procedure_info.argument_types.count - 1 {
//             if procedure_info.argument_types[i].type != .STRING {
//                 return false;
//             }
//         }

//         return true;
//     }(), "You cannot have optional arguments that are non-strings.");

//     #if path == "*" {
//         assert(!server.fallback_handlers[cast(int) method], "You cannot have both optional handlers and static handlers.");
//         assert(!server.fallback_handlers_with_options[cast(int) method], "You cannot override an existing handler callback.");
//         server.fallback_handlers_with_options[cast(int) method] = .{cast(*void) handler, T};
//     } else {
//         final_handler := add_handler(*server.handlers[cast(int) method], path);
//         assert(!final_handler.callback, "You cannot have both optional handlers and static handlers.");
//         assert(!final_handler.callback_with_options, "You cannot override an existing handler callback.");
//         final_handler.callback_with_options = .{cast(*void) handler, T};
//     }
// }

// handle :: (server: *HttpServer, method: HttpMethod, $path: string, $handler: $T) {
//     #run assert(starts_with(path, "/"), "Your handler path must start with either \"/\" or \"*\".");
//     #run assert(find_index_from_left(path, #char "*") > 0, "You cannot provide static paths in your optional request handler.");

//     #run print("%\n", type_info(T));

//     // TODO match the number of optionals to the number of vargs

//     final_handler := add_handler(*server.handlers[cast(int) method], path);
//     assert(!final_handler.callback_with_options, "You cannot override an existing handler callback.");
//     final_handler.callback_with_options = handler;
// }

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, body: string, memory_mode: HttpMemoryMode) -> HttpResult {
    assert(body.count == 0 || body[body.count - 1] == #char "\0", "Your body must either be null or must end with a null character.");

    body_count: int;
    if body.count > 0 {
        body_count = body.count - 1;
    }

    return inline reply(response, status, extra_headers, body.data, body_count, memory_mode);
}

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, $body: *u8) -> HttpResult {
    body_count :: #run (body: *u8) -> int {
        if !body {
            return 0;
        }

        return c_style_strlen(body);
    }(body);

    return inline reply(response, status, extra_headers, body, body_count, .Static);
}

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, body: *u8, memory_mode: HttpMemoryMode) -> HttpResult {
    body_count: int;
    if body {
        body_count = c_style_strlen(body);
    }

    return inline reply(response, status, extra_headers, body, body_count, memory_mode);
}

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, body: *u8, body_length: int, memory_mode: HttpMemoryMode) -> HttpResult {
    mhd_response: *MHD_Response;
    if #complete memory_mode == {
        case .Static;
            mhd_response = MHD_create_response_from_buffer_static(cast(u64) body_length, body);
        case .Allocated;
            mhd_response = MHD_create_response_from_buffer_with_free_callback_cls(cast(u64) body_length, body, memory_free_callback, cast(*void) response.server);
        case .Copy;
            mhd_response = MHD_create_response_from_buffer_copy(cast(u64) body_length, body);
    }

    if !mhd_response {
        return .{.MHD_NO};
    }

    for extra_header: response.server.extra_headers {
        MHD_add_response_header(mhd_response, extra_header[0], extra_header[1]);
    }

    for extra_header: extra_headers {
        MHD_add_response_header(mhd_response, extra_header[0], extra_header[1]);
    }

    ret := MHD_queue_response(response.connection, status, mhd_response);
    MHD_destroy_response(mhd_response);

    return .{ret};
}

reply_error :: () -> HttpResult {
    return .{MHD_NO};
}

get_form_data :: (request: *HttpRequest, name: string) -> *string {
    for entry: request.form_data {
        if entry.name == name {
            return *entry.value;
        }
    }

    return null;
}

#scope_file

destroy_handler :: (handler: HttpHandler) {
    // we don't free the part string because it's just a segment of a compile time string
    // we also don't free any handlers because they're just pointers to global functions
    for child: handler.children {
        destroy_handler(child);
    }

    if handler.optional {
        destroy_handler(handler.optional);
        free(handler.optional);
    }

    array_free(handler.children);
}

get_handler :: (handler: *HttpHandler, path: string, optional_parts: *[..] string) -> *HttpHandler {
    if !path {
        return null;
    }

    // check if this is a base path, nothing or slashes
    path_part, next_index := get_next_path_part(path, 0);
    if !path_part && next_index == path.count {
        return handler;
    }

    next_handler: *HttpHandler = handler;
    optional_parts.count = 0;

    index := 0;
    while index < path.count && next_handler {
        path_part, next_index := get_next_path_part(path, index);

        if path_part {
            static_handler := get_static_handler(*next_handler.children, path_part);
            if static_handler {
                next_handler = static_handler;
            } else if next_handler.optional {
                next_handler = next_handler.optional;
                array_add(optional_parts, path_part);
            } else {
                next_handler = null;
            }
        }

        index = next_index;
    }

    return next_handler;
}

add_handler :: (handler: *HttpHandler, $path: string) -> *HttpHandler {
    #if path[0] == #char "*" {
        return handler;
    }

    current_handler: *HttpHandler = handler;

    index := 0;
    while index < path.count {
        path_part, next_index := get_next_path_part(path, index);

        if !path_part {
            return current_handler;
        } else if path_part == "*" {
            if !current_handler.optional {
                current_handler.optional = New(HttpHandler);
                current_handler.optional.part = "*";
            }

            current_handler = current_handler.optional;
        } else {
            static_handler := get_static_handler(*current_handler.children, path_part);
            print("looking for static handler for %\n", path_part);
            print("looking in children\n");
            for child: current_handler.children {
                print("\t%\n", child);
            }
            print("found %\n", static_handler);
            if !static_handler {
                handler_entry: HttpHandler;
                handler_entry.part = path_part;

                static_handler = sorted_insert(*current_handler.children, handler_entry, (a: HttpHandler, b: HttpHandler) -> int {
                    return string_compare(a.part, b.part);
                });
            }

            current_handler = static_handler;
        }

        index = next_index;
    }

    return current_handler;
}

get_static_handler :: (handlers: *[..] HttpHandler, part: string) -> *HttpHandler {
    lower_bound := 0;
    upper_bound := handlers.count - 1;

    while lower_bound <= upper_bound {
        check_index := (lower_bound + upper_bound) / 2;

        diff := string_compare(handlers.*[check_index].part, part);
        if diff < 0 {
            lower_bound = check_index + 1;
        } else if diff > 0 {
            upper_bound = check_index - 1;
        } else {
            lower_bound = check_index;
            upper_bound = check_index;
            return *handlers.*[check_index];
        }
    }

    return null;
}

get_optional_count :: (path: string) -> int {
    if path.count == 0 {
        return 0;
    }

    count := 0;

    index := 0;
    while index < path.count {
        path_part, next_index := get_next_path_part(path, index);

        if path_part == "*" {
            count += 1;
        }

        index = next_index;
    }

    return count;
}

get_next_path_part :: (path: string, index: int) -> string, int {
    while index < path.count && is_slash(path, index) {
        index += 1;
    }

    count := 0;
    while index + count < path.count && !is_slash(path, index + count) {
        count += 1;
    }

    part: string;
    part.data = path.data + index;
    part.count = count;

    // get rid of the trailing slashes for the new index
    while index + count < path.count && is_slash(path, index + count) {
        count += 1;
    }

    return part, index + count;
}

get_thread_context :: (server: *HttpServer) -> Context #c_call {
    push_context global_http_context {
        context.allocator = server.allocator;

        thread_id := get_thread_id();

        threads_propagated := server.threads_propagated;
        if !threads_propagated {
            lock(*server.thread_contexts_mutex);
        }

        thread_context_pointer := table_find_pointer(*server.thread_contexts, thread_id);
        if !thread_context_pointer {
            thread_context_pointer = table_add(*server.thread_contexts, thread_id, create_thread_context(server, thread_id));
        }

        if !threads_propagated {
            threads_propagated = server.thread_contexts.count >= server.thread_count;
            unlock(*server.thread_contexts_mutex);
        }

        return thread_context_pointer.*;
    }
}

create_thread_context :: (server: *HttpServer, thread_id: u64) -> Context {
    truncated_thread_id: u32;
    truncated_thread_id = (cast(u32) (thread_id & 0xffffffff)) ^ (cast(u32) ((thread_id >> 32) & 0xffffffff));

    temporary_storage_size := 16384;

    thread_context: Context;
    thread_context.thread_index = truncated_thread_id;
    thread_context.base.context_info = type_info(Context);
    thread_context.allocator = server.allocator;
    thread_context.temporary_storage = New(Temporary_Storage);
    set_initial_data(thread_context.temporary_storage, temporary_storage_size, alloc(temporary_storage_size));

    return thread_context;
}

free_thread_context :: (server: *HttpServer, thread_context: Context) {
    push_context global_http_context {
        context.allocator = server.allocator;

        free(thread_context.temporary_storage.original_data);

        overflow := thread_context.temporary_storage.overflow_pages;
        while overflow {
            free(overflow);
            overflow = overflow.next;
        }
    }
}

get_thread_id :: () -> u64 {
    #if OS == .WINDOWS {
        #import "Windows";
        
        return cast(u64) GetCurrentThreadId();
    } else #if OS == .LINUX {
        #import "POSIX";

        return pthread_self();
    } else #if OS == .MACOS {
        #import "POSIX";

        thread_id: u64;
        pthread_threadid_np(null, *thread_id);
        return thread_id;
    } else {
        assert(false, "Unknown OS.");
        return 0;
    }
}

memory_free_callback :: (cls: *void) #c_call {
    server := cast(*HttpServer) cls;
    thread_context := get_thread_context(server);

    push_context thread_context {
        free(cls);
    }
}

// normalize_url :: (url: string) -> string {
//     if !url {
//         return url;
//     }

//     normalized := url;
//     while normalized[normalized.count - 1] == #char "/" {
//         normalized.count -= 1;
//     }

//     // theres a lot of other stuff that should be done, like changing forward
//     // slash to backslash or whatever
//     // but right now I'm not willing to allocate strings
//     // if I want to do this more intensely in the future I should just change
//     // the server to have a fixed array of bytes as keys

//     return normalized;
// }

get_http_method :: (method: string) -> HttpMethod {
    if method == {
        case "CONNECT";
            return .Connect;
        case "DELETE";
            return .Delete;
        case "GET";
            return .Get;
        case "HEAD";
            return .Head;
        case "OPTIONS";
            return .Options;
        case "PATCH";
            return .Patch;
        case "POST";
            return .Post;
        case "PUT";
            return .Put;
        case "TRACE";
            return .Trace;
        case;
            return .Fallback;
    }
}

server_respond :: (cls: *void, connection: *MHD_Connection, url: *u8, method: *u8, version: *u8, upload_data: *u8, upload_data_size: *u64, req_cls: **void) -> MHD_Result #c_call {
    request_time := get_unix_time();
    server := cast(*HttpServer) cls;
    thread_context := get_thread_context(server);

    push_context thread_context {
        url_string := to_string(url);
        method_string := to_string(method);
        http_method := get_http_method(method_string);

        http_request := cast(*HttpRequest) req_cls.*;
        http_response := HttpResponse.{
            server,
            connection,
        };

        if !http_request {
            http_request = New(HttpRequest);
            req_cls.* = http_request;

            if !http_request {
                return .MHD_NO;
            }

            // my assumption is that this will stay alive until the end of the request
            content_type := MHD_lookup_connection_value(connection, .HEADER_KIND, MHD_HTTP_HEADER_CONTENT_TYPE);
            http_request.content_type = to_string(content_type);
            
            http_request.server = server;
        }

        // if it's a post method we have to propagate the form data
        if http_method == .Post && (http_request.content_type == MHD_HTTP_POST_ENCODING_FORM_URLENCODED || http_request.content_type == MHD_HTTP_POST_ENCODING_MULTIPART_FORMDATA) {
            if !http_request.post_processor {
                http_request.post_processor = MHD_create_post_processor(connection, 1024, iterate_post, cast(*void) http_request);
                if !http_request.post_processor {
                    req_cls.* = null;
                    free(http_request);

                    return .MHD_NO;
                }

                return .MHD_YES;
            }

            if upload_data_size.* != 0 {
                // if we've already received an error then we give up on post processing and just keep iterating until we're done
                if http_request.error {
                    upload_data_size.* = 0;

                    return .MHD_YES;
                }

                if MHD_post_process(http_request.post_processor, upload_data, upload_data_size.*) != .MHD_YES {
                    http_request.error = true;
                }

                upload_data_size.* = 0;
                return .MHD_YES;
            }
        }

        // TODO need to remove all duplicate slashes and trailing slashes, and maybe store each / part as its own thing so I can match wildcards
        // first try to get the full path of the correct method
        handler: InternalRequestHandler;

        optional_parts: [..] string;
        defer array_free(optional_parts);

        path_handler := get_handler(*server.handlers[cast(int) http_method], url_string, *optional_parts);
        if path_handler {
            handler = path_handler.callback;
        }
        // otherwise try to get the fallback path of the correct method
        if !handler {
            handler = server.fallback_handlers[cast(int) http_method];
            if handler {
                // maybe I should curate the path myself, lowercase and normalize slashes and all that in fallbacks
                // probably only if the method indicates they have optionals
                optional_parts.count = 0;
                array_add(*optional_parts, url_string);
            }
        }
        // if it's a head request, repeat this using the get method
        if !handler && http_method == .Head {
            path_handler := get_handler(*server.handlers[cast(int) HttpMethod.Get], url_string, *optional_parts);
            if path_handler {
                handler = path_handler.callback;
            }
            if !handler {
                handler = server.fallback_handlers[cast(int) HttpMethod.Get];
                if handler {
                    optional_parts.count = 0;
                    array_add(*optional_parts, url_string);
                }
            }
        }
        if !handler {
            // otherwise try to get the full path of the fallback method
            path_handler := get_handler(*server.handlers[cast(int) HttpMethod.Fallback], url_string, *optional_parts);
            if path_handler {
                handler = path_handler.callback;
            }
            // otherwise try to get the fallback path of the fallback method
            if !handler {
                handler = server.fallback_handlers[cast(int) HttpMethod.Fallback];
                if handler {
                    optional_parts.count = 0;
                    array_add(*optional_parts, url_string);
                }
            }
        }

        // otherwise return not found
        if !handler {
            print("No valid fallback found. Begrudgingly returning 404.\n");
            handler = default_not_found_handler;
            optional_parts.count = 0;
            array_add(*optional_parts, url_string);
        }

        http_result := handler(http_request, *http_response, optional_parts);

        reset_temporary_storage();

        return http_result.result;
    }
}

iterate_post :: (cls: *void, kind: MHD_ValueKind, key: *u8, filename: *u8, content_type: *u8, transfer_encoding: *u8, data: *u8, off: u64, size: size_t) -> MHD_Result #c_call {
    http_request := cast(*HttpRequest) cls;

    push_context global_http_context {
        context.allocator = http_request.server.allocator;

        key_string := to_string(key);

        existing_entry: *HttpFormEntry;
        for *entry: http_request.form_data {
            if entry.name == key_string {
                existing_entry = entry;
                break;
            }
        }

        if !existing_entry {
            existing_entry = array_add(*http_request.form_data);
            if !existing_entry {
                return .MHD_NO;
            }

            existing_entry.name = copy_string(key_string);
            if filename {
                existing_entry.filename = copy_string(to_string(filename));
            }
        }

        if size > 0 {
            if !existing_entry.value.data {
                existing_entry.value.data = alloc(cast(int) size);
            } else {
                existing_entry.value.data = realloc(existing_entry.value.data, existing_entry.value.count + cast(int) size, existing_entry.value.count);
            }
            memcpy(existing_entry.value.data + existing_entry.value.count, data, cast(int) size);
            existing_entry.value.count += cast(int) size;
        }

        return .MHD_YES;
    }
}

server_completed :: (cls: *void, connection: *MHD_Connection, req_cls: **void, toe: MHD_RequestTerminationCode) #c_call {
    http_request := cast(*HttpRequest) req_cls.*;

    push_context global_http_context {
        context.allocator = http_request.server.allocator;

        if !http_request {
            return;
        }

        for entry: http_request.form_data {
            free(entry.name);
            free(entry.filename);
            free(entry.value);
        }
        array_free(http_request.form_data);

        if http_request.post_processor {
            MHD_destroy_post_processor(http_request.post_processor);
        }

        free(http_request);

        req_cls.* = null;
    }
}

get_unix_time :: () -> u64 #c_call {
    #if OS == .WINDOWS {
        #import "Windows";

        filetime: FILETIME;
        GetSystemTimePreciseAsFileTime(*filetime);

        UNIX_TIME_START: s64 : 0x019DB1DED53E8000;
        TICKS_PER_SECOND: s64 : 10000;

        li: LARGE_INTEGER;
        li.LowPart = xx filetime.dwLowDateTime;
        li.HighPart = xx filetime.dwHighDateTime;

        return cast(u64) ((li.QuadPart - UNIX_TIME_START) / TICKS_PER_SECOND);
    } else #if OS == .LINUX {
        #import "POSIX";

        t: timespec;
        clock_gettime(CLOCK_REALTIME, *t);
        micros: s64 = t.tv_sec * 1000000;
        /* Add full microseconds */
        micros += t.tv_nsec / 1000;

        return cast(u64) micros / 1000;
    } else {
        return 0;
    }
}

is_slash :: inline (path: string, index: int) -> bool {
    return path[index] == #char "/" || path[index] == #char "\\";
}

lower_char :: inline (char: u8) -> u8 {
    if char >= #char "A" && char <= #char "Z"
        return char + #char "a" - #char "A";

    return char;
}

string_compare :: inline (a: string, b: string) -> int {
    min_count := min(a.count, b.count);

    diff: int;
    count: int;
    while diff == 0 && count < min_count {
        diff = cast(int) lower_char(a[count]) - cast(int) lower_char(b[count]);
        count += 1;
    }

    if diff == 0 {
        if count < a.count {
            return 1;
        }

        if count < b.count {
            return -1;
        }
    }

    return diff;
}

// #run () {
//     sorted: [..] string;
//     sorted_insert(*sorted, "frontpage", string_compare);
//     sorted_insert(*sorted, "asd", string_compare);
//     sorted_insert(*sorted, "asd", string_compare);
//     sorted_insert(*sorted, "frontpage", string_compare);
//     print("generated %\n", sorted);
// }();

sorted_insert :: (array: *[..] $T, entry: T, $compare: (T, T) -> $R) -> *T {
    lower_bound := 0;
    upper_bound := array.count - 1;
    while lower_bound < upper_bound - 1 {
        check_index := (lower_bound + upper_bound) / 2;

        diff := compare(array.*[check_index], entry);
        if diff < 0 {
            lower_bound = check_index;
        } else if diff > 0 {
            upper_bound = check_index;
        } else {
            lower_bound = check_index;
            upper_bound = check_index;
        }
    }

    insert := max(lower_bound, upper_bound);
    if array.count > 0 {
        if compare(array.*[insert], entry) < 0 {
            insert += 1;
        }
    }

    array_insert_at(array, entry, insert);

    #if true {
        for i: 0..array.count - 2 {
            if compare(array.*[i], array.*[i + 1]) > 0 {
                print("Sorted insert didn't work. %\n", entry);
                for entry: array.* {
                    print("\t%\n", entry);
                }
                assert(false);
            }
        }
    }

    return *array.*[insert];
}

global_http_context: Context;

default_not_found_handler := (request: *HttpRequest, response: *HttpResponse, optionals: [] string) -> HttpResult {
    return reply(response, 404, .[], null);
}

core_count :: #run get_number_of_processors();
http_method_count :: cast(u16) HttpMethod.Fallback + 1;

#import "libmicrohttpd-jai";

#import "Basic";
#import "Math";
#import "System";
#import "Thread";
#import "Hash_Table";
#import "String";

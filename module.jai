
HttpServer :: struct {
    port: u16;
    timeout_seconds: int;
    thread_count: int;
    daemon: *MHD_Daemon;
    handlers: [http_method_count] Table(string, RequestHandler);
    extra_headers: [] [2] *u8;
    // once this is flipped to true we'll no longer lock the mutex since the table will never again change
    threads_propagated: bool;
    thread_contexts_mutex: Mutex;
    thread_contexts: Table(u64, Context);
    allocator: Allocator;
}

HttpFormEntry :: struct {
    name: string;
    filename: string;
    value: string;
}

HttpRequest :: struct {
    server: *HttpServer;
    form_data: [..] HttpFormEntry;
    post_processor: *MHD_PostProcessor;
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

RequestHandler :: #type (request: *HttpRequest, response: *HttpResponse) -> HttpResult;

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
    for *handler: server.handlers {
        deinit(handler);
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

handle :: (server: *HttpServer, method: HttpMethod, $path: string, handler: RequestHandler) {
    table_set(*server.handlers[cast(u16) method], normalize_url(path), handler);
}

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

normalize_url :: (url: string) -> string {
    normalized := url;
    while normalized[normalized.count - 1] == #char "/" {
        normalized.count -= 1;
    }

    // theres a lot of other stuff that should be done, like changing forward
    // slash to backslash or whatever
    // but right now I'm not willing to allocate strings
    // if I want to do this more intensely in the future I should just change
    // the server to have a fixed array of bytes as keys

    return normalized;
}

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
        url_string := normalize_url(to_string(url));
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
            
            http_request.server = server;
        }

        // if it's a post method we have to propagate the form data
        if http_method == .Post {
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

        handler := table_find_pointer(*server.handlers[cast(int) http_method], url_string);
        if !handler {
            handler = table_find_pointer(*server.handlers[cast(int) http_method], "*");
        }
        if !handler && http_method == .Head {
            // libmicrohttpd automatically handles removing the body so we'll fallback to get requests without any extra data
            handler = table_find_pointer(*server.handlers[cast(int) HttpMethod.Get], url_string);
            if !handler {
                handler = table_find_pointer(*server.handlers[cast(int) HttpMethod.Get], "*");
            }
        }
        if !handler {
            handler = table_find_pointer(*server.handlers[cast(int) HttpMethod.Fallback], url_string);
        }
        if !handler {
            handler = table_find_pointer(*server.handlers[cast(int) HttpMethod.Fallback], "*");
        }
        if !handler {
            print("No valid fallback found. Begrudgingly returning 404.\n");
            handler = *default_not_found_handler;
        }

        http_result := handler.*(http_request, *http_response);

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

global_http_context: Context;

default_not_found_handler := (request: *HttpRequest, response: *HttpResponse) -> HttpResult {
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

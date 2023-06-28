
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
}

HttpRequest :: struct {
    
}

HttpResponse :: struct {
    server: *HttpServer;
    connection: *MHD_Connection;
    extra_headers: [] [2] *u8;
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

create_server :: (port: u16, timeout_seconds: int = 60, thread_count: int = core_thread_count) -> *HttpServer {
    server := New(HttpServer);
    server.port = port;
    server.timeout_seconds = timeout_seconds;
    server.thread_count = thread_count;

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
        cast(u32) MHD_FLAG.MHD_USE_INTERNAL_POLLING_THREAD,
        server.port,
        null,
        null,
        server_respond,
        cast(*void) server,
        MHD_OPTION.MHD_OPTION_THREAD_POOL_SIZE, server.thread_count,
        MHD_OPTION.MHD_OPTION_CONNECTION_TIMEOUT, server.timeout_seconds,
        MHD_OPTION.MHD_OPTION_END);

    // TODO I can't figure out how to assert on temp allocations so I'll
    // TODO just have to actually give a new context to each thread and
    // TODO clear the temp allocator for each context (if its even unique?) after each request

    return server.daemon != null;
}

server_stop :: (server: *HttpServer) {
    print("Stopping server on port %...\n", server.port);

    MHD_stop_daemon(server.daemon);

    for thread_context, thread_id: server.thread_contexts {
        free_thread_context(thread_context);
    }
    deinit(*server.thread_contexts);
    server.threads_propagated = false;
}

handle :: (server: *HttpServer, method: HttpMethod, $path: string, handler: RequestHandler) {
    table_set(*server.handlers[cast(u16) method], normalize_url(path), handler);
}

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, $body: string) -> HttpResult {
    return inline reply(response, status, extra_headers, body, .Static);
}

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, body: string, memory_mode: HttpMemoryMode) -> HttpResult {
    assert(body.count == 0 || body[body.count - 1] == #char "\0", "Your body must either be null or must end with a null character.");

    body_count: u64;
    if body.count > 0 {
        body_count = cast(u64) body.count - 1;
    }

    return inline reply(response, status, extra_headers, body_count, body.data, memory_mode);
}

reply :: (response: *HttpResponse, status: u16, extra_headers: [] [2] *u8, body_length: u64, body: *u8, memory_mode: HttpMemoryMode) -> HttpResult {
    body_length := cast(u64) c_style_strlen(body);
    mhd_response: *MHD_Response;
    if #complete memory_mode == {
        case .Static;
            mhd_response = MHD_create_response_from_buffer_static(body_length, body);
        case .Allocated;
            mhd_response = MHD_create_response_from_buffer_with_free_callback_cls(body_length, body, memory_free_callback, cast(*void) response.server);
        case .Copy;
            mhd_response = MHD_create_response_from_buffer_copy(body_length, body);
    }

    if !mhd_response {
        return .{.MHD_NO};
    }

    for extra_header: response.extra_headers {
        MHD_add_response_header(mhd_response, extra_header[0], extra_header[1]);
    }

    for extra_header: extra_headers {
        MHD_add_response_header(mhd_response, extra_header[0], extra_header[1]);
    }

    ret := MHD_queue_response(response.connection, status, mhd_response);
    MHD_destroy_response(mhd_response);

    return .{ret};
}

#scope_file

get_thread_context :: (server: *HttpServer) -> Context #c_call {
    push_context global_http_context {
        thread_id := get_thread_id();

        threads_propagated := server.threads_propagated;
        if !threads_propagated {
            lock(*server.thread_contexts_mutex);
        }

        thread_context_pointer := table_find_pointer(*server.thread_contexts, thread_id);
        if !thread_context_pointer {
            thread_context_pointer = table_add(*server.thread_contexts, thread_id, create_thread_context(thread_id));
        }

        if !threads_propagated {
            threads_propagated = server.thread_contexts.count >= server.thread_count;
            unlock(*server.thread_contexts_mutex);
        }

        return thread_context_pointer.*;
    }
}

create_thread_context :: (thread_id: u64) -> Context {
    truncated_thread_id: u32;
    truncated_thread_id = (cast(u32) (thread_id & 0xffffffff)) ^ (cast(u32) ((thread_id >> 32) & 0xffffffff));

    temporary_storage_size := 16384;

    thread_context: Context;
    thread_context.thread_index = truncated_thread_id;
    thread_context.base.context_info = type_info(Context);
    thread_context.allocator = global_http_context.allocator;
    thread_context.logger = global_http_context.logger;
    thread_context.logger_data = global_http_context.logger_data;
    thread_context.temporary_storage = New(Temporary_Storage);
    set_initial_data(thread_context.temporary_storage, temporary_storage_size, alloc(temporary_storage_size));

    return thread_context;
}

free_thread_context :: (thread_context: Context) {
    push_context global_http_context {
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
    server := cast(*HttpServer) cls;
    thread_context := get_thread_context(server);

    push_context thread_context {
        url_string := normalize_url(to_string(url));
        method_string := to_string(method);

        http_request := HttpRequest.{};
        http_response := HttpResponse.{
            server,
            connection,
            server.extra_headers,
        };

        http_method := get_http_method(method_string);
        handler := table_find_pointer(*server.handlers[cast(u16) http_method], url_string);
        if !handler {
            handler = table_find_pointer(*server.handlers[cast(u16) http_method], "*");
        }
        if !handler {
            handler = table_find_pointer(*server.handlers[cast(u16) HttpMethod.Fallback], url_string);
        }
        if !handler {
            handler = table_find_pointer(*server.handlers[cast(u16) HttpMethod.Fallback], "*");
        }
        if !handler {
            print("No valid fallback found. Begrudgingly returning 404.\n");
            handler = *default_not_found_handler;
        }

        reset_temporary_storage();

        http_result := handler.*(*http_request, *http_response);
        return http_result.result;
    }
}

global_http_context: Context;

default_not_found_handler := (request: *HttpRequest, response: *HttpResponse) -> HttpResult {
    return reply(response, 404, .[], "");
}

// finished_propagating_contexts: bool;
// required_thread_count: int;
// thread_contexts_mutex_initialized: bool;
// thread_contexts_mutex: Mutex;

// thread_contexts: Table(u64, Context);

core_count :: #run get_number_of_processors();
core_thread_count :: core_count * 2;
http_method_count :: cast(u16) HttpMethod.Fallback + 1;

#import "libmicrohttpd-jai";

#import "Basic";
#import "Math";
#import "System";
#import "Thread";
#import "Hash_Table";

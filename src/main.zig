const std = @import("std");
const builtin = @import("builtin");

const max_attempts = 10;
const request_prompt = "请输入需求: ";
const max_retry_feedback_bytes = 2048;

const Message = struct {
    role: []const u8,
    content: []const u8,
};

const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: f32,
};

const Suggestion = struct {
    command: []const u8,
    executable: []const u8,
};

const ExecutionDecision = enum {
    execute,
    regenerate,
    cancel,
};

const CommandRunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

pub fn main() void {
    run() catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const request = try readUserRequest(allocator);
    defer allocator.free(request);

    const api_key = std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY") catch {
        try printUsage();
        std.debug.print("error: missing DEEPSEEK_API_KEY environment variable\n", .{});
        return;
    };
    defer allocator.free(api_key);

    const api_url = std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_URL") catch
        try allocator.dupe(u8, "https://api.deepseek.com/chat/completions");
    defer allocator.free(api_url);

    const model = std.process.getEnvVarOwned(allocator, "DEEPSEEK_MODEL") catch
        try allocator.dupe(u8, "deepseek-chat");
    defer allocator.free(model);

    const system_info = try collectSystemInfo(allocator);
    defer allocator.free(system_info);

    var last_command: ?[]u8 = null;
    var last_executable: ?[]u8 = null;
    var failure_history: ?[]u8 = null;
    defer {
        if (last_command) |cmd| allocator.free(cmd);
        if (last_executable) |exe| allocator.free(exe);
        if (failure_history) |history| allocator.free(history);
    }

    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const prompt = try buildPrompt(allocator, system_info, request, attempt, failure_history);
        defer allocator.free(prompt);

        const raw_command = requestCommandFromDeepSeek(allocator, api_url, api_key, model, prompt) catch |err| {
            std.debug.print("failed to query DeepSeek on attempt {d}: {s}\n", .{ attempt + 1, @errorName(err) });
            return err;
        };
        errdefer allocator.free(raw_command);

        const trimmed = std.mem.trim(u8, raw_command, " \t\r\n");
        if (trimmed.len == 0) {
            allocator.free(raw_command);
            continue;
        }

        const command = try allocator.dupe(u8, trimmed);
        allocator.free(raw_command);

        const executable_name = extractExecutable(command) orelse {
            allocator.free(command);
            continue;
        };
        const executable = try allocator.dupe(u8, executable_name);

        if (last_command) |prev| allocator.free(prev);
        if (last_executable) |prev| allocator.free(prev);
        last_command = command;
        last_executable = executable;

        if (try commandExists(allocator, executable)) {
            switch (try confirmExecution(command)) {
                .execute => {},
                .regenerate => {
                    const entry = try formatUserRejectedSuggestion(allocator, attempt + 1, command);
                    defer allocator.free(entry);
                    failure_history = try appendFailureHistory(allocator, failure_history, entry);
                    continue;
                },
                .cancel => {
                    std.debug.print("canceled\n", .{});
                    return;
                },
            }

            const result = try runCommand(allocator, command);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.exit_code == 0) {
                std.process.exit(0);
            }

            std.debug.print("command exited with code {d}\n", .{result.exit_code});
            if (result.stdout.len > 0) {
                std.debug.print("stdout:\n{s}\n", .{result.stdout});
            }
            if (result.stderr.len > 0) {
                std.debug.print("stderr:\n{s}\n", .{result.stderr});
            }

            const retry = try confirmRetryWithDeepSeek();
            if (!retry) {
                std.process.exit(result.exit_code);
            }

            const entry = try formatExecutionFailure(allocator, attempt + 1, command, result.exit_code, result.stdout, result.stderr);
            defer allocator.free(entry);
            failure_history = try appendFailureHistory(allocator, failure_history, entry);
            continue;
        }

        const entry = try formatMissingExecutableFailure(allocator, attempt + 1, command, executable);
        defer allocator.free(entry);
        failure_history = try appendFailureHistory(allocator, failure_history, entry);
        std.debug.print("attempt {d}/{d}: `{s}` not found, asking DeepSeek for an alternative...\n", .{ attempt + 1, max_attempts, executable });
    }

    const missing = last_executable orelse "unknown";
    const cmd = last_command orelse "unavailable";
    std.debug.print("failed after {d} attempts\n", .{max_attempts});
    std.debug.print("last suggested command: {s}\n", .{cmd});
    if (failure_history) |history| {
        std.debug.print("failure history:\n{s}\n", .{history});
    } else {
        std.debug.print("missing executable: {s}\n", .{missing});
        std.debug.print("please install the related tool and try again\n", .{});
    }
}

fn printUsage() !void {
    std.debug.print(
        \\usage:
        \\  cla "查看 cpu"
        \\  cla
        \\
        \\env:
        \\  DEEPSEEK_API_KEY   required
        \\  DEEPSEEK_API_URL   optional, default https://api.deepseek.com/chat/completions
        \\  DEEPSEEK_MODEL     optional, default deepseek-chat
        \\
    , .{});
}

fn readUserRequest(allocator: std.mem.Allocator) ![]u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        return try std.mem.join(allocator, " ", args[1..]);
    }

    try std.fs.File.stdout().writeAll(request_prompt);
    return try readInteractiveLine(allocator);
}

fn readInteractiveLine(allocator: std.mem.Allocator) ![]u8 {
    const stdin = std.fs.File.stdin();
    const reader = stdin.deprecatedReader();
    if (!stdin.isTty()) {
        return try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
    }

    const original_termios = std.posix.tcgetattr(stdin.handle) catch {
        return try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
    };

    var raw_termios = original_termios;
    raw_termios.lflag.ICANON = false;
    raw_termios.lflag.ECHO = false;
    raw_termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw_termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    std.posix.tcsetattr(stdin.handle, .NOW, raw_termios) catch {
        return try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
    };
    defer std.posix.tcsetattr(stdin.handle, .NOW, original_termios) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    const stdout = std.fs.File.stdout();
    var byte_buffer: [1]u8 = undefined;

    while (true) {
        const read_len = try stdin.read(&byte_buffer);
        if (read_len == 0) break;

        const byte = byte_buffer[0];
        switch (byte) {
            '\r', '\n' => {
                try stdout.writeAll("\r\n");
                break;
            },
            3 => {
                try stdout.writeAll("^C\r\n");
                return error.UserAborted;
            },
            8, 127 => {
                removeLastUtf8Codepoint(&bytes);
                try redrawInteractiveLine(stdout, bytes.items);
            },
            else => {
                if (byte < 32) continue;
                try bytes.append(allocator, byte);
                try stdout.writeAll(byte_buffer[0..1]);
            },
        }
    }

    return try bytes.toOwnedSlice(allocator);
}

fn redrawInteractiveLine(stdout: std.fs.File, line: []const u8) !void {
    try stdout.writeAll("\r\x1b[2K");
    try stdout.writeAll(request_prompt);
    try stdout.writeAll(line);
}

fn removeLastUtf8Codepoint(bytes: *std.ArrayList(u8)) void {
    if (bytes.items.len == 0) return;

    var idx = bytes.items.len - 1;
    while (idx > 0 and isUtf8ContinuationByte(bytes.items[idx])) : (idx -= 1) {}
    bytes.items.len = idx;
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

fn collectSystemInfo(allocator: std.mem.Allocator) ![]u8 {
    const shell = std.process.getEnvVarOwned(allocator, "SHELL") catch try allocator.dupe(u8, "unknown");
    defer allocator.free(shell);

    const path = std.process.getEnvVarOwned(allocator, "PATH") catch try allocator.dupe(u8, "unknown");
    defer allocator.free(path);

    const platform_name = try detectPlatformName(allocator);
    defer allocator.free(platform_name);

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch try allocator.dupe(u8, ".");
    defer allocator.free(cwd);

    return try std.fmt.allocPrint(
        allocator,
        \\OS: {s}
        \\Kernel OS tag: {s}
        \\Architecture: {s}
        \\Shell: {s}
        \\Working directory: {s}
        \\PATH: {s}
        \\
    ,
        .{
            platform_name,
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            shell,
            cwd,
            path,
        },
    );
}

fn detectPlatformName(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .linux => readLinuxPrettyName(allocator) catch allocator.dupe(u8, "Linux"),
        .macos => allocator.dupe(u8, "macOS"),
        else => allocator.dupe(u8, @tagName(builtin.os.tag)),
    };
}

fn readLinuxPrettyName(allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.openFileAbsolute("/etc/os-release", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 16 * 1024);
    errdefer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PRETTY_NAME=")) continue;
        const raw = line["PRETTY_NAME=".len..];
        const trimmed = std.mem.trim(u8, raw, "\"");
        const pretty = try allocator.dupe(u8, trimmed);
        allocator.free(content);
        return pretty;
    }

    return content;
}

fn buildPrompt(
    allocator: std.mem.Allocator,
    system_info: []const u8,
    user_request: []const u8,
    attempt: usize,
    failure_history: ?[]const u8,
) ![]u8 {
    if (attempt == 0) {
        return try std.fmt.allocPrint(
            allocator,
            \\你是一个 Unix 命令行助手，目标环境可能是 Linux 或 macOS。根据用户需求返回一个最合适的 shell 命令。
            \\要求：
            \\1. 只返回一条命令，不要解释，不要 Markdown，不要代码块。
            \\2. 优先使用常见、已安装概率高的系统自带工具，并结合系统信息判断当前环境是 Linux 还是 macOS。
            \\3. 尽量避免管道、重定向、shell 内建和复杂脚本。
            \\4. 命令必须能直接在 `sh -lc` 下执行。
            \\5. 如果需求只是查看信息，命令不要修改系统。
            \\
            \\系统信息：
            \\{s}
            \\用户需求：
            \\{s}
        ,
            .{ system_info, user_request },
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        \\你是一个 Unix 命令行助手，目标环境可能是 Linux 或 macOS。之前给出的命令已经失败过，请基于完整失败历史换一个方案。
        \\要求：
        \\1. 只返回一条命令，不要解释，不要 Markdown，不要代码块。
        \\2. 优先使用常见、已安装概率高的系统自带工具，并结合系统信息判断当前环境是 Linux 还是 macOS。
        \\3. 尽量避免管道、重定向、shell 内建和复杂脚本。
        \\4. 命令必须能直接在 `sh -lc` 下执行。
        \\5. 必须结合完整失败历史，避免重复使用同样会失败的程序、参数或思路。
        \\
        \\系统信息：
        \\{s}
        \\用户需求：
        \\{s}
        \\
        \\失败历史：
        \\{s}
    ,
        .{
            system_info,
            user_request,
            failure_history orelse "无",
        },
    );
}

fn requestCommandFromDeepSeek(
    allocator: std.mem.Allocator,
    api_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    prompt: []const u8,
) ![]u8 {
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const messages = [_]Message{
        .{ .role = "system", .content = "You generate exactly one shell command for the user's request." },
        .{ .role = "user", .content = prompt },
    };
    const payload_struct = ChatRequest{
        .model = model,
        .messages = &messages,
        .temperature = 0.1,
    };

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(payload_struct, .{}, &payload_writer.writer);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(api_url);
    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
        },
        .payload = payload_writer.written(),
        .response_writer = &response_body.writer,
    });

    if (result.status != .ok) {
        std.debug.print("deepseek api returned status {d}\n", .{@intFromEnum(result.status)});
        return error.DeepSeekRequestFailed;
    }

    return try extractMessageContent(allocator, response_body.written());
}

fn extractMessageContent(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const choices_value = parsed.value.object.get("choices") orelse return error.InvalidApiResponse;
    const choices = switch (choices_value) {
        .array => |array| array,
        else => return error.InvalidApiResponse,
    };
    if (choices.items.len == 0) return error.InvalidApiResponse;

    const first = choices.items[0];
    const message_value = first.object.get("message") orelse return error.InvalidApiResponse;
    const message = switch (message_value) {
        .object => |object| object,
        else => return error.InvalidApiResponse,
    };

    const content_value = message.get("content") orelse return error.InvalidApiResponse;
    const content = switch (content_value) {
        .string => |string| string,
        else => return error.InvalidApiResponse,
    };

    return normalizeCommand(allocator, content);
}

fn normalizeCommand(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "```")) {
        const first_newline = std.mem.indexOfScalar(u8, text, '\n') orelse return allocator.dupe(u8, text);
        text = text[first_newline + 1 ..];
        if (std.mem.lastIndexOf(u8, text, "```")) |idx| {
            text = text[0..idx];
        }
        text = std.mem.trim(u8, text, " \t\r\n");
    }

    if (std.mem.indexOfScalar(u8, text, '\n')) |idx| {
        text = text[0..idx];
    }

    return try allocator.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
}

fn extractExecutable(command: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (parts.next()) |token| {
        if (std.mem.eql(u8, token, "sudo")) continue;
        if (std.mem.eql(u8, token, "env")) continue;
        if (token.len > 1 and std.mem.indexOfScalar(u8, token, '=') != null and std.ascii.isAlphabetic(token[0])) continue;
        return token;
    }
    return null;
}

fn commandExists(allocator: std.mem.Allocator, executable: []const u8) !bool {
    const script = try std.fmt.allocPrint(allocator, "command -v -- {s} >/dev/null 2>&1", .{executable});
    defer allocator.free(script);

    var child = std.process.Child.init(&.{ "sh", "-lc", script }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    return switch (try child.spawnAndWait()) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn confirmExecution(command: []const u8) !ExecutionDecision {
    std.debug.print("准备执行命令:\n{s}\n", .{command});
    std.debug.print("确认执行？[y/N/r(重新提供)]: ", .{});

    const stdin = std.fs.File.stdin().deprecatedReader();
    var line_buffer: [64]u8 = undefined;
    const line = try stdin.readUntilDelimiterOrEof(&line_buffer, '\n');
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");

    if (std.ascii.eqlIgnoreCase(answer, "y") or
        std.ascii.eqlIgnoreCase(answer, "yes") or
        std.mem.eql(u8, answer, "是"))
    {
        return .execute;
    }

    if (std.ascii.eqlIgnoreCase(answer, "r") or
        std.ascii.eqlIgnoreCase(answer, "retry") or
        std.mem.eql(u8, answer, "重新提供"))
    {
        return .regenerate;
    }

    return .cancel;
}

fn confirmRetryWithDeepSeek() !bool {
    std.debug.print("是否将失败信息发给 DeepSeek 并重试？[y/N]: ", .{});

    const stdin = std.fs.File.stdin().deprecatedReader();
    var line_buffer: [64]u8 = undefined;
    const line = try stdin.readUntilDelimiterOrEof(&line_buffer, '\n');
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");

    return std.ascii.eqlIgnoreCase(answer, "y") or
        std.ascii.eqlIgnoreCase(answer, "yes") or
        std.mem.eql(u8, answer, "是");
}

fn runCommand(allocator: std.mem.Allocator, command: []const u8) !CommandRunResult {
    const stdout_log = try makeTempLogPath(allocator, "stdout");
    defer allocator.free(stdout_log);
    const stderr_log = try makeTempLogPath(allocator, "stderr");
    defer allocator.free(stderr_log);

    try createEmptyFile(stdout_log);
    try createEmptyFile(stderr_log);
    defer std.fs.deleteFileAbsolute(stdout_log) catch {};
    defer std.fs.deleteFileAbsolute(stderr_log) catch {};

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("CLA_COMMAND", command);
    try env_map.put("CLA_STDOUT_LOG", stdout_log);
    try env_map.put("CLA_STDERR_LOG", stderr_log);

    var child = std.process.Child.init(&.{
        "bash",
        "-lc",
        "bash -lc \"$CLA_COMMAND\" > >(tee \"$CLA_STDOUT_LOG\") 2> >(tee \"$CLA_STDERR_LOG\" >&2)",
    }, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    const stdout = try readLogFile(allocator, stdout_log);
    const stderr = try readLogFile(allocator, stderr_log);

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .Exited => |code| code,
            .Signal => |sig| @intCast(128 + sig),
            else => 1,
        },
    };
}

fn formatExecutionFailure(
    allocator: std.mem.Allocator,
    attempt_no: usize,
    command: []const u8,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    const clipped_stdout = clipForRetry(stdout);
    const clipped_stderr = clipForRetry(stderr);

    return try std.fmt.allocPrint(
        allocator,
        \\[{d}] execution_failed
        \\命令：{s}
        \\退出码：{d}
        \\stdout：
        \\{s}
        \\
        \\stderr：
        \\{s}
    ,
        .{ attempt_no, command, exit_code, clipped_stdout, clipped_stderr },
    );
}

fn formatMissingExecutableFailure(
    allocator: std.mem.Allocator,
    attempt_no: usize,
    command: []const u8,
    executable: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        \\[{d}] missing_executable
        \\命令：{s}
        \\缺失程序：{s}
    ,
        .{ attempt_no, command, executable },
    );
}

fn formatUserRejectedSuggestion(
    allocator: std.mem.Allocator,
    attempt_no: usize,
    command: []const u8,
) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        \\[{d}] user_requested_alternative
        \\命令：{s}
        \\原因：用户要求重新提供一个方案，不能重复当前命令或同样思路
    ,
        .{ attempt_no, command },
    );
}

fn appendFailureHistory(
    allocator: std.mem.Allocator,
    current: ?[]u8,
    entry: []const u8,
) ![]u8 {
    if (current) |history| {
        const updated = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ history, entry });
        allocator.free(history);
        return updated;
    }

    return try allocator.dupe(u8, entry);
}

fn clipForRetry(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "(empty)";
    if (trimmed.len <= max_retry_feedback_bytes) return trimmed;
    return trimmed[0..max_retry_feedback_bytes];
}

fn makeTempLogPath(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const tmp_dir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_dir);

    return try std.fmt.allocPrint(
        allocator,
        "{s}/cla-{d}-{s}.log",
        .{ std.mem.trimRight(u8, tmp_dir, "/"), std.time.nanoTimestamp(), suffix },
    );
}

fn createEmptyFile(path: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    file.close();
}

fn readLogFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => return err,
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

test "normalize strips code fences" {
    const allocator = std.testing.allocator;
    const result = try normalizeCommand(allocator,
        \\```bash
        \\ls -lah
        \\```
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings("ls -lah", result);
}

test "extract executable skips sudo and env" {
    try std.testing.expectEqualStrings("df", extractExecutable("sudo env LANG=C df -h /") orelse "");
}

test "removeLastUtf8Codepoint removes a full utf8 character" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, "abc\xe4\xb8\xad");
    removeLastUtf8Codepoint(&bytes);

    try std.testing.expectEqualStrings("abc", bytes.items);
}

test "formatUserRejectedSuggestion records regenerate request" {
    const allocator = std.testing.allocator;
    const result = try formatUserRejectedSuggestion(allocator, 2, "ls -lah");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "user_requested_alternative") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ls -lah") != null);
}

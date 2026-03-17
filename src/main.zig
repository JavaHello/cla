const std = @import("std");
const builtin = @import("builtin");

const max_attempts = 3;

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
    defer {
        if (last_command) |cmd| allocator.free(cmd);
        if (last_executable) |exe| allocator.free(exe);
    }

    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const prompt = try buildPrompt(allocator, system_info, request, attempt, last_command, last_executable);
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
            const confirmed = try confirmExecution(command);
            if (!confirmed) {
                std.debug.print("canceled\n", .{});
                return;
            }

            const exit_code = try runCommand(allocator, command);
            std.process.exit(exit_code);
        }

        std.debug.print("attempt {d}/{d}: `{s}` not found, asking DeepSeek for an alternative...\n", .{ attempt + 1, max_attempts, executable });
    }

    const missing = last_executable orelse "unknown";
    const cmd = last_command orelse "unavailable";
    std.debug.print("failed after {d} attempts\n", .{max_attempts});
    std.debug.print("last suggested command: {s}\n", .{cmd});
    std.debug.print("missing executable: {s}\n", .{missing});
    std.debug.print("please install the related tool and try again\n", .{});
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

    std.debug.print("请输入需求: ", .{});
    const stdin = std.fs.File.stdin().deprecatedReader();
    return try stdin.readUntilDelimiterAlloc(allocator, '\n', 4096);
}

fn collectSystemInfo(allocator: std.mem.Allocator) ![]u8 {
    const shell = std.process.getEnvVarOwned(allocator, "SHELL") catch try allocator.dupe(u8, "unknown");
    defer allocator.free(shell);

    const path = std.process.getEnvVarOwned(allocator, "PATH") catch try allocator.dupe(u8, "unknown");
    defer allocator.free(path);

    const pretty_name = readOsPrettyName(allocator) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(pretty_name);

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
            pretty_name,
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            shell,
            cwd,
            path,
        },
    );
}

fn readOsPrettyName(allocator: std.mem.Allocator) ![]u8 {
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
    last_command: ?[]const u8,
    last_executable: ?[]const u8,
) ![]u8 {
    if (attempt == 0) {
        return try std.fmt.allocPrint(
            allocator,
            \\你是一个 Linux 命令行助手。根据用户需求返回一个最合适的 shell 命令。
            \\要求：
            \\1. 只返回一条命令，不要解释，不要 Markdown，不要代码块。
            \\2. 优先使用常见、已安装概率高的 Linux 工具。
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
        \\你是一个 Linux 命令行助手。之前给出的命令不可用，请换一个方案。
        \\要求：
        \\1. 只返回一条命令，不要解释，不要 Markdown，不要代码块。
        \\2. 必须更换为其他可执行程序，不能继续使用 `{s}`。
        \\3. 优先选择标准 Linux 环境中更常见的工具。
        \\4. 尽量避免管道、重定向、shell 内建和复杂脚本。
        \\5. 命令必须能直接在 `sh -lc` 下执行。
        \\
        \\系统信息：
        \\{s}
        \\用户需求：
        \\{s}
        \\
        \\上一条失败命令：
        \\{s}
        \\
        \\失败原因：
        \\本地未找到可执行程序 `{s}`，请改用别的命令。
    ,
        .{
            last_executable orelse "unknown",
            system_info,
            user_request,
            last_command orelse "unknown",
            last_executable orelse "unknown",
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

fn confirmExecution(command: []const u8) !bool {
    std.debug.print("准备执行命令:\n{s}\n", .{command});
    std.debug.print("确认执行？[y/N]: ", .{});

    const stdin = std.fs.File.stdin().deprecatedReader();
    var line_buffer: [64]u8 = undefined;
    const line = try stdin.readUntilDelimiterOrEof(&line_buffer, '\n');
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");

    return std.ascii.eqlIgnoreCase(answer, "y") or
        std.ascii.eqlIgnoreCase(answer, "yes") or
        std.mem.eql(u8, answer, "是");
}

fn runCommand(allocator: std.mem.Allocator, command: []const u8) !u8 {
    var child = std.process.Child.init(&.{ "sh", "-lc", command }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    return switch (try child.spawnAndWait()) {
        .Exited => |code| code,
        .Signal => |sig| @intCast(128 + sig),
        else => 1,
    };
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

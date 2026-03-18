# cla

一个使用 Zig 编写的命令行 AI。它会把用户需求和当前系统信息发给 DeepSeek，让模型生成适合本机的 shell 命令，然后在本地检查命令是否存在，必要时最多重试 3 次；如果命令执行失败，也可以把失败信息回报给 DeepSeek 再试一次，并累计多轮失败历史，最后由用户确认是否继续。当前支持 Linux 和 macOS。

## 功能

- 支持命令行参数或交互式输入需求
- 支持在 Linux 和 macOS 下运行
- 将系统信息作为提示词发给 DeepSeek
- 本地检查建议命令是否可执行
- 缺少命令时回传失败原因给 DeepSeek 继续改写，最多 3 次
- 命令执行失败后，可选择把退出码和输出回报给 DeepSeek 再重试
- 多轮失败信息会累计发送给 DeepSeek，避免来回重复推荐
- 命令可用时提示用户确认执行，也可选择让 DeepSeek 重新提供一个方案

## 环境变量

- `DEEPSEEK_API_KEY`：必填
- `DEEPSEEK_API_URL`：可选，默认 `https://api.deepseek.com/chat/completions`
- `DEEPSEEK_MODEL`：可选，默认 `deepseek-chat`

## 构建

```bash
zig build
```

## 运行

```bash
DEEPSEEK_API_KEY=your_key zig build run -- "查看 cpu"
```

或者：

```bash
DEEPSEEK_API_KEY=your_key ./zig-out/bin/cla
```

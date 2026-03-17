# cla

一个使用 Zig 编写的命令行 AI。它会把用户需求和当前系统信息发给 DeepSeek，让模型生成适合本机的 shell 命令，然后在本地检查命令是否存在，必要时最多重试 3 次，最后由用户确认是否执行。

## 功能

- 支持命令行参数或交互式输入需求
- 将系统信息作为提示词发给 DeepSeek
- 本地检查建议命令是否可执行
- 缺少命令时回传失败原因给 DeepSeek 继续改写，最多 3 次
- 命令可用时提示用户确认执行

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

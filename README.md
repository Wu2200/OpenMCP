# OpenMCP (iOS)

原生 iOS AI 对话与工具调度客户端。

## 功能特性

- **自定义 OpenAI 兼容接口**：支持任意 OpenAI 格式服务端点（DeepSeek, OpenAI, Moonshot, Groq, Ollama, OneAPI, NewAPI 等）。
- **Model Context Protocol (MCP) 原生工具调用**：支持挂载多个远程 MCP 服务，自动发现工具定义并驱动大模型多轮 Function Calling 闭环。
- **纯原生 SwiftUI**：无三方厚重依赖，极简响应式架构与现代化聊天界面。
- **GitHub Actions 自动化打包**：推送即触发免签 IPA 构建，自动生成 Release 下载包。

# NGM proofread

macOS 原生 OCR 翻译校对工具，支持截图/图片上传、Vision 框架文字识别、手动文字输入、多模型 AI 翻译与语法分析。

## 功能

- **图片识别**：截图或上传图片，macOS Vision 框架本地 OCR，支持中/日/英，无需网络
- **文字输入**：手动输入/粘贴日文原文，跳过 OCR 直接翻译分析
- **AI 翻译**：DeepSeek / ChatGPT / Gemini 多模型支持，翻译 + 句子成分分析
- **两种分析模式**：
  - 校对模式 — 语法树拆解句子成分，辅助核对翻译准确性
  - 学习模式 — 语法树 + 语法点详解（附例句）+ 词汇注解（N1~N2）
- **图片框选**：拖拽创建选区 + 8 手柄精调，缩放/平移，OCR 范围精准映射
- **词汇查询**：内嵌查词输入框，读音/释义/词性/JLPT/例句，Cmd+K 快捷聚焦
- **术语表**：设置自定义词汇翻译映射，AI 翻译严格遵循
- **TTS 朗读**：`AVSpeechSynthesizer` 本地日语语音朗读

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本

## 安装

从 [Releases](../../releases) 下载 DMG，双击打开，将 NGM proofread 拖入 Applications 文件夹。

## 技术栈

SwiftUI + Swift · macOS 14+ · Vision 框架 · DeepSeek/OpenAI/Gemini API · AVFoundation

## 许可证

开发者：NJRin  
技术支持：虹之咲学园 Vibe Coding 同好会

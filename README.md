# Audio2Txt (macOS)

一个 Swift 原生小工具：选择本地 `m4a/mp3` 音频（支持多选），调用火山引擎「豆包语音妙记」进行转写，完成后保存为带时间戳的 `.txt`。

## 功能

- 普通窗口 App（SwiftUI）
- 选择本地音频文件（`m4a/mp3/wav/aiff`，支持多选）
- 自动上传到 TOS（临时对象）
- 调用妙记 `submit/query` 异步转写
- 单文件：完成后弹出「另存为」窗口（默认：`原音频名.txt`）
- 多文件：先选择一个输出目录，然后批量写入同名 `.txt`
- 输出格式：`[HH:mm:ss.SSS] [speaker] 文本`（内置短词自动合并，避免一词一行）
- 默认会删除 TOS 临时音频对象
- 默认会额外保存一份同名 `.raw.json`（可通过 `SAVE_RAW_JSON=false` 关闭），用于排查妙记原始返回

## 准备

1. 复制配置模板：

```bash
cp .env.example .env
```

2. 按 `.env` 填写参数（尤其是 `VOLC_*` 与 `TOS_*`）。

## 运行

```bash
swift run Audio2TxtApp
```

> 首次运行需要在系统里允许应用访问文件。

## 说明

- 妙记接口是离线异步流程，音频提交后会轮询状态。
- 默认轮询间隔 `30s`，最长等待 `120min`，可在 `.env` 调整。
- 批量任务默认并发数为 `2`，可通过 `MAX_CONCURRENT_JOBS` 调整。
- 如果你后续改为 STS 临时凭证，可直接填 `TOS_STS_TOKEN`，代码已预留。

## 参考

- 豆包语音妙记 API：<https://www.volcengine.com/docs/6561/1798094?lang=zh>
- TOS SDK 概览：<https://www.volcengine.com/docs/6349/93480?lang=zh>
- Access Key 管理：<https://www.volcengine.com/docs/6291/65568?lang=zh>

# 豆包语音妙记（Windows C++ 重写版）

这是基于原有 Swift/Electron 版本的 **C++ 原生 Windows 重写分支**。

## 当前状态
- 已完成：
  - Win32 原生窗口 UI（按钮、文件列表、进度条、日志）
  - 多文件选择、清空重选
  - 转写任务线程框架
  - 本地配置读写（`%APPDATA%\\DoubaoMinutesWinCpp\\settings.env`）
  - 文本保存流程（单文件另存，多文件选目录）
- 进行中：
  - TOS 签名上传 + 妙记 submit/query + JSON 解析（将逐步迁移 Swift 版本逻辑）

## 构建（Windows）
建议环境：
- Visual Studio 2022（Desktop development with C++）
- CMake 3.20+

```powershell
cd windows-cpp-app
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

产物：
- `build/Release/DoubaoMinutesWinCpp.exe`

## 后续迁移计划
1. 先补 `TranscriptionService` 的 WinHTTP 调用（上传/submit/query/download）
2. 再补 TOS4-HMAC-SHA256 签名与预签名 URL
3. 接着迁移摘要/翻译/时间戳格式化策略
4. 最后补完整设置面板 UI 与应用图标资源

# 豆包语音妙记（Windows 桌面版）

本目录是 Windows 版桌面应用（Electron）。

## 功能
- 多音频选择（支持跨文件夹）
- 并发转写（上传 -> 提交 -> 轮询 -> 下载）
- 转写结果保存为同名 txt（单文件可自定义文件名，多文件选目录）
- 可选保存 `.raw.json`
- 设置面板（核心参数 + 高级选项）
- 翻译父子开关（默认关闭，开启后默认英语 -> 中文）

## 开发运行
```bash
npm install
npm run dev
```

## Windows 打包 EXE
请在 **Windows 机器** 上执行：
```bash
npm install
npm run pack:win
```

输出目录：
- `windows-app/dist/`

说明：
- 目前目标是 `portable`，会产出可直接运行的 `.exe`。
- 若你需要安装包，可用：`npm run pack:win:nsis`。

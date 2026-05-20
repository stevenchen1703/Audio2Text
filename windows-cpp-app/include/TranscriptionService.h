#pragma once

#include "AppSettings.h"

#include <functional>
#include <string>
#include <vector>

struct TranscriptionResult {
  std::wstring inputFile;
  std::wstring outputText;
  std::string rawJson;
};

class TranscriptionService {
public:
  using LogFn = std::function<void(const std::wstring&)>;
  using ProgressFn = std::function<void(double, const std::wstring&)>;

  explicit TranscriptionService(AppSettings settings);

  // 批量转写（当前为骨架实现，便于先完成 C++ 原生架构迁移）
  bool transcribeBatch(
    const std::vector<std::wstring>& files,
    std::vector<TranscriptionResult>& outResults,
    std::wstring& err,
    const LogFn& log,
    const ProgressFn& progress
  );

private:
  AppSettings settings_;

  std::wstring makeOutputHeader() const;
};

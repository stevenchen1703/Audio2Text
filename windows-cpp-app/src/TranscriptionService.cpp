#include "TranscriptionService.h"

#include <Windows.h>

#include <chrono>
#include <iomanip>
#include <sstream>

namespace {

std::wstring nowClock() {
  SYSTEMTIME st{};
  GetLocalTime(&st);
  wchar_t buf[32]{};
  swprintf_s(buf, L"[%02d:%02d:%02d]", st.wHour, st.wMinute, st.wSecond);
  return buf;
}

std::wstring basenameOf(const std::wstring& p) {
  const size_t pos = p.find_last_of(L"\\/");
  if (pos == std::wstring::npos) return p;
  return p.substr(pos + 1);
}

} // namespace

TranscriptionService::TranscriptionService(AppSettings settings)
  : settings_(std::move(settings)) {}

std::wstring TranscriptionService::makeOutputHeader() const {
  SYSTEMTIME st{};
  GetLocalTime(&st);

  const int hour = st.wHour;
  const bool isPM = hour >= 12;
  int h12 = hour % 12;
  if (h12 == 0) h12 = 12;

  wchar_t buf[128]{};
  swprintf_s(
    buf,
    L"%04d年%d月%d日 %s %d:%02d|未知时长",
    st.wYear,
    st.wMonth,
    st.wDay,
    isPM ? L"下午" : L"上午",
    h12,
    st.wMinute
  );
  return buf;
}

bool TranscriptionService::transcribeBatch(
  const std::vector<std::wstring>& files,
  std::vector<TranscriptionResult>& outResults,
  std::wstring& err,
  const LogFn& log,
  const ProgressFn& progress
) {
  outResults.clear();

  if (files.empty()) {
    err = L"请先选择音频文件";
    return false;
  }

  std::string missing;
  if (!settings_.isValid(missing)) {
    err = L"缺少配置项: ";
    err += std::wstring(missing.begin(), missing.end());
    return false;
  }

  // 当前版本先完成 Win32 原生框架与数据流改造。
  // 下一迭代将把 Swift 版的 TOS 签名、submit/query、结果解析逻辑逐个迁移到 C++ 网络层。
  log(nowClock() + L" 开始执行上传 -> 提交 -> 轮询 -> 下载流程");
  log(nowClock() + L" 并发任务数: " + std::to_wstring(std::max(1, settings_.maxConcurrentJobs)));

  const size_t total = files.size();
  for (size_t i = 0; i < total; ++i) {
    const auto& f = files[i];
    const std::wstring name = basenameOf(f);

    log(nowClock() + L" [" + name + L"] 开始任务");
    log(nowClock() + L" [" + name + L"] C++ 网络核心迁移中：当前为骨架版本，暂未发起真实 API 请求");

    std::wstringstream ss;
    ss << makeOutputHeader() << L"\n\n"
       << L"全文总结:\n"
       << L"当前为 C++ 重写骨架版本，已完成 Windows 原生 UI、设置持久化、日志与任务流框架。\n\n"
       << L"文字记录:\n"
       << L"00:00\n"
       << L"[占位] 下一迭代将接入真实转写结果。";

    TranscriptionResult one;
    one.inputFile = f;
    one.outputText = ss.str();
    outResults.push_back(std::move(one));

    const double p = static_cast<double>(i + 1) / static_cast<double>(total);
    progress(p, L"转写进度 " + std::to_wstring(static_cast<int>(p * 100)) + L"%");
  }

  log(nowClock() + L" 全部任务完成");
  return true;
}

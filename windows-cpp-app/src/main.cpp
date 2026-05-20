#include "AppSettings.h"
#include "TranscriptionService.h"

#include <Windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <atomic>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "Comctl32.lib")

namespace {

constexpr wchar_t kClassName[] = L"DoubaoMinutesWinCppMain";
constexpr int IDC_ADD = 1001;
constexpr int IDC_CLEAR = 1002;
constexpr int IDC_START = 1003;
constexpr int IDC_SETTINGS = 1004;
constexpr int IDC_LIST = 1005;
constexpr int IDC_LOG = 1006;
constexpr int IDC_PROGRESS = 1007;
constexpr int IDC_STATUS = 1008;

constexpr UINT WM_APP_LOG = WM_APP + 1;
constexpr UINT WM_APP_PROGRESS = WM_APP + 2;
constexpr UINT WM_APP_DONE = WM_APP + 3;

struct UiState {
  HWND hwnd{};
  HWND btnAdd{};
  HWND btnClear{};
  HWND btnStart{};
  HWND btnSettings{};
  HWND listFiles{};
  HWND editLog{};
  HWND progress{};
  HWND status{};

  AppSettings settings;
  std::vector<std::wstring> files;
  std::atomic<bool> running{false};
};

std::wstring nowClock() {
  SYSTEMTIME st{};
  GetLocalTime(&st);
  wchar_t buf[32]{};
  swprintf_s(buf, L"[%02d:%02d:%02d]", st.wHour, st.wMinute, st.wSecond);
  return buf;
}

void appendLog(UiState* st, const std::wstring& line) {
  if (!st || !st->editLog) return;
  const std::wstring payload = line + L"\r\n";
  SendMessageW(st->editLog, EM_SETSEL, static_cast<WPARAM>(-1), static_cast<LPARAM>(-1));
  SendMessageW(st->editLog, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(payload.c_str()));
}

void setStatus(UiState* st, const std::wstring& text) {
  if (!st || !st->status) return;
  SetWindowTextW(st->status, text.c_str());
}

void refreshFileList(UiState* st) {
  if (!st || !st->listFiles) return;
  SendMessageW(st->listFiles, LB_RESETCONTENT, 0, 0);
  if (st->files.empty()) {
    SendMessageW(st->listFiles, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"未选择文件"));
    setStatus(st, L"请选择一个或多个 m4a/mp3 音频文件");
    EnableWindow(st->btnStart, FALSE);
    return;
  }

  for (const auto& f : st->files) {
    SendMessageW(st->listFiles, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(f.c_str()));
  }

  setStatus(st, L"已选择 " + std::to_wstring(st->files.size()) + L" 个文件");
  EnableWindow(st->btnStart, st->running ? FALSE : TRUE);
}

std::vector<std::wstring> pickFiles(HWND owner) {
  std::vector<std::wstring> out;

  IFileOpenDialog* dlg = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)))) {
    return out;
  }

  DWORD opts = 0;
  dlg->GetOptions(&opts);
  dlg->SetOptions(opts | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST);

  COMDLG_FILTERSPEC filters[] = {
    { L"音频文件", L"*.mp3;*.m4a;*.wav;*.aiff" },
    { L"全部文件", L"*.*" },
  };
  dlg->SetFileTypes(static_cast<UINT>(std::size(filters)), filters);
  dlg->SetTitle(L"添加课程录音（可多选）");

  if (SUCCEEDED(dlg->Show(owner))) {
    IShellItemArray* items = nullptr;
    if (SUCCEEDED(dlg->GetResults(&items)) && items) {
      DWORD count = 0;
      items->GetCount(&count);
      for (DWORD i = 0; i < count; ++i) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(items->GetItemAt(i, &item)) && item) {
          PWSTR p = nullptr;
          if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p)) && p) {
            out.emplace_back(p);
            CoTaskMemFree(p);
          }
          item->Release();
        }
      }
      items->Release();
    }
  }

  dlg->Release();
  return out;
}

std::wstring chooseSingleOutput(HWND owner, const std::wstring& inputFile) {
  IFileSaveDialog* dlg = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)))) {
    return L"";
  }

  COMDLG_FILTERSPEC filters[] = {
    { L"文本文件", L"*.txt" },
  };
  dlg->SetFileTypes(1, filters);
  dlg->SetDefaultExtension(L"txt");
  dlg->SetTitle(L"保存转写文本");

  const size_t slash = inputFile.find_last_of(L"\\/");
  std::wstring fileName = (slash == std::wstring::npos) ? inputFile : inputFile.substr(slash + 1);
  const size_t dot = fileName.find_last_of(L'.');
  if (dot != std::wstring::npos) fileName = fileName.substr(0, dot);
  fileName += L".txt";
  dlg->SetFileName(fileName.c_str());

  std::wstring out;
  if (SUCCEEDED(dlg->Show(owner))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dlg->GetResult(&item)) && item) {
      PWSTR p = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p)) && p) {
        out = p;
        CoTaskMemFree(p);
      }
      item->Release();
    }
  }

  dlg->Release();
  return out;
}

std::wstring chooseOutputFolder(HWND owner) {
  IFileOpenDialog* dlg = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)))) {
    return L"";
  }

  DWORD opts = 0;
  dlg->GetOptions(&opts);
  dlg->SetOptions(opts | FOS_PICKFOLDERS | FOS_PATHMUSTEXIST);
  dlg->SetTitle(L"选择批量输出文件夹");

  std::wstring out;
  if (SUCCEEDED(dlg->Show(owner))) {
    IShellItem* item = nullptr;
    if (SUCCEEDED(dlg->GetResult(&item)) && item) {
      PWSTR p = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p)) && p) {
        out = p;
        CoTaskMemFree(p);
      }
      item->Release();
    }
  }

  dlg->Release();
  return out;
}

std::wstring toOutputPath(const std::wstring& dir, const std::wstring& inputFile) {
  const size_t slash = inputFile.find_last_of(L"\\/");
  std::wstring name = (slash == std::wstring::npos) ? inputFile : inputFile.substr(slash + 1);
  const size_t dot = name.find_last_of(L'.');
  if (dot != std::wstring::npos) name = name.substr(0, dot);
  return dir + L"\\" + name + L".txt";
}

void openSettingsHint(UiState* st) {
  const std::wstring path = getSettingsFilePath();
  std::wstring msg =
    L"当前 C++ 版先用本地配置文件方式管理参数：\n\n" + path +
    L"\n\n你可以先运行一次转写，程序会在该路径自动写入设置。\n"
    L"下一迭代会补齐图形化设置面板。";
  MessageBoxW(st->hwnd, msg.c_str(), L"设置说明", MB_OK | MB_ICONINFORMATION);
}

void beginTranscription(UiState* st) {
  if (!st || st->running) return;
  if (st->files.empty()) {
    setStatus(st, L"请先选择音频文件");
    return;
  }

  st->running = true;
  EnableWindow(st->btnStart, FALSE);
  EnableWindow(st->btnAdd, FALSE);
  EnableWindow(st->btnClear, FALSE);
  EnableWindow(st->btnSettings, FALSE);
  SendMessageW(st->progress, PBM_SETPOS, 0, 0);

  appendLog(st, nowClock() + L" 开始执行上传 -> 提交 -> 轮询 -> 下载流程");

  std::thread([st]() {
    std::vector<TranscriptionResult> results;
    std::wstring err;

    TranscriptionService service(st->settings);
    const bool ok = service.transcribeBatch(
      st->files,
      results,
      err,
      [st](const std::wstring& line) {
        auto* s = new std::wstring(line);
        PostMessageW(st->hwnd, WM_APP_LOG, 0, reinterpret_cast<LPARAM>(s));
      },
      [st](double value, const std::wstring& text) {
        auto* payload = new std::pair<double, std::wstring>(value, text);
        PostMessageW(st->hwnd, WM_APP_PROGRESS, 0, reinterpret_cast<LPARAM>(payload));
      }
    );

    if (!ok) {
      auto* s = new std::wstring(L"错误: " + err);
      PostMessageW(st->hwnd, WM_APP_LOG, 0, reinterpret_cast<LPARAM>(s));
      PostMessageW(st->hwnd, WM_APP_DONE, FALSE, 0);
      return;
    }

    if (st->settings.completionSoundEnabled) {
      MessageBeep(MB_OK);
    }

    auto* s = new std::wstring(nowClock() + L" 转写已完成，开始选择保存位置");
    PostMessageW(st->hwnd, WM_APP_LOG, 0, reinterpret_cast<LPARAM>(s));

    bool saved = true;
    if (st->files.size() == 1) {
      const auto out = chooseSingleOutput(st->hwnd, st->files[0]);
      if (out.empty()) {
        saved = false;
      } else {
        std::wofstream os(out, std::ios::binary | std::ios::trunc);
        if (os.is_open()) {
          os << results[0].outputText;
          os.close();
        }
      }
    } else {
      const auto dir = chooseOutputFolder(st->hwnd);
      if (dir.empty()) {
        saved = false;
      } else {
        for (size_t i = 0; i < st->files.size() && i < results.size(); ++i) {
          const auto out = toOutputPath(dir, st->files[i]);
          std::wofstream os(out, std::ios::binary | std::ios::trunc);
          if (os.is_open()) {
            os << results[i].outputText;
            os.close();
          }
        }
      }
    }

    auto* done = new std::wstring(saved ? L"全部任务完成" : L"已取消保存");
    PostMessageW(st->hwnd, WM_APP_LOG, 0, reinterpret_cast<LPARAM>(done));
    PostMessageW(st->hwnd, WM_APP_DONE, TRUE, 0);
  }).detach();
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  UiState* st = reinterpret_cast<UiState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

  switch (msg) {
  case WM_CREATE: {
    auto* cs = reinterpret_cast<LPCREATESTRUCTW>(lParam);
    auto* init = reinterpret_cast<UiState*>(cs->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(init));
    init->hwnd = hwnd;

    init->btnAdd = CreateWindowW(L"BUTTON", L"添加音频", WS_CHILD | WS_VISIBLE, 20, 20, 110, 30, hwnd, reinterpret_cast<HMENU>(IDC_ADD), nullptr, nullptr);
    init->btnClear = CreateWindowW(L"BUTTON", L"清空并重选", WS_CHILD | WS_VISIBLE, 140, 20, 120, 30, hwnd, reinterpret_cast<HMENU>(IDC_CLEAR), nullptr, nullptr);
    init->btnStart = CreateWindowW(L"BUTTON", L"开始转写", WS_CHILD | WS_VISIBLE, 270, 20, 110, 30, hwnd, reinterpret_cast<HMENU>(IDC_START), nullptr, nullptr);
    init->btnSettings = CreateWindowW(L"BUTTON", L"设置", WS_CHILD | WS_VISIBLE, 390, 20, 80, 30, hwnd, reinterpret_cast<HMENU>(IDC_SETTINGS), nullptr, nullptr);

    init->progress = CreateWindowW(PROGRESS_CLASSW, nullptr, WS_CHILD | WS_VISIBLE, 20, 60, 640, 18, hwnd, reinterpret_cast<HMENU>(IDC_PROGRESS), nullptr, nullptr);
    SendMessageW(init->progress, PBM_SETRANGE, 0, MAKELPARAM(0, 100));

    init->status = CreateWindowW(L"STATIC", L"请选择一个或多个 m4a/mp3 音频文件", WS_CHILD | WS_VISIBLE, 20, 84, 640, 24, hwnd, reinterpret_cast<HMENU>(IDC_STATUS), nullptr, nullptr);

    init->listFiles = CreateWindowW(L"LISTBOX", nullptr, WS_CHILD | WS_VISIBLE | WS_BORDER | LBS_NOINTEGRALHEIGHT, 20, 110, 640, 170, hwnd, reinterpret_cast<HMENU>(IDC_LIST), nullptr, nullptr);

    init->editLog = CreateWindowW(
      L"EDIT",
      nullptr,
      WS_CHILD | WS_VISIBLE | WS_BORDER | ES_LEFT | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY | WS_VSCROLL,
      20,
      300,
      640,
      220,
      hwnd,
      reinterpret_cast<HMENU>(IDC_LOG),
      nullptr,
      nullptr
    );

    refreshFileList(init);
    return 0;
  }

  case WM_COMMAND: {
    if (!st) break;
    const int id = LOWORD(wParam);
    switch (id) {
    case IDC_ADD: {
      const auto picked = pickFiles(hwnd);
      if (!picked.empty()) {
        st->files.insert(st->files.end(), picked.begin(), picked.end());
        appendLog(st, nowClock() + L" 新增 " + std::to_wstring(picked.size()) + L" 个文件");
        refreshFileList(st);
      }
      return 0;
    }
    case IDC_CLEAR: {
      st->files.clear();
      refreshFileList(st);
      const auto picked = pickFiles(hwnd);
      if (!picked.empty()) {
        st->files = picked;
        refreshFileList(st);
      }
      return 0;
    }
    case IDC_START:
      beginTranscription(st);
      return 0;
    case IDC_SETTINGS:
      openSettingsHint(st);
      return 0;
    default:
      break;
    }
    break;
  }

  case WM_APP_LOG: {
    if (st && lParam) {
      std::unique_ptr<std::wstring> ptr(reinterpret_cast<std::wstring*>(lParam));
      appendLog(st, *ptr);
    }
    return 0;
  }

  case WM_APP_PROGRESS: {
    if (st && lParam) {
      std::unique_ptr<std::pair<double, std::wstring>> ptr(reinterpret_cast<std::pair<double, std::wstring>*>(lParam));
      const int p = static_cast<int>(ptr->first * 100.0);
      SendMessageW(st->progress, PBM_SETPOS, static_cast<WPARAM>(p), 0);
      setStatus(st, ptr->second);
    }
    return 0;
  }

  case WM_APP_DONE: {
    if (st) {
      st->running = false;
      EnableWindow(st->btnStart, st->files.empty() ? FALSE : TRUE);
      EnableWindow(st->btnAdd, TRUE);
      EnableWindow(st->btnClear, TRUE);
      EnableWindow(st->btnSettings, TRUE);
      SendMessageW(st->progress, PBM_SETPOS, 100, 0);
    }
    return 0;
  }

  case WM_CLOSE:
    DestroyWindow(hwnd);
    return 0;

  case WM_DESTROY:
    PostQuitMessage(0);
    return 0;

  default:
    break;
  }

  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int nCmdShow) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);

  INITCOMMONCONTROLSEX icex{};
  icex.dwSize = sizeof(icex);
  icex.dwICC = ICC_PROGRESS_CLASS;
  InitCommonControlsEx(&icex);

  UiState state;
  state.settings = loadSettings();

  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = hInst;
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);

  RegisterClassW(&wc);

  HWND hwnd = CreateWindowExW(
    0,
    kClassName,
    L"豆包语音妙记（C++ 重写版）",
    WS_OVERLAPPEDWINDOW,
    CW_USEDEFAULT,
    CW_USEDEFAULT,
    700,
    600,
    nullptr,
    nullptr,
    hInst,
    &state
  );

  if (!hwnd) {
    CoUninitialize();
    return 1;
  }

  ShowWindow(hwnd, nCmdShow);
  UpdateWindow(hwnd);

  MSG msg{};
  while (GetMessageW(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }

  CoUninitialize();
  return 0;
}

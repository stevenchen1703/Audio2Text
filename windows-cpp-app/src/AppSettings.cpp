#include "AppSettings.h"

#include <Windows.h>
#include <ShlObj.h>

#include <fstream>
#include <sstream>
#include <vector>

namespace {

std::wstring utf8ToWide(const std::string& input) {
  if (input.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, nullptr, 0);
  if (size <= 0) return L"";
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, out.data(), size);
  return out;
}

std::string wideToUtf8(const std::wstring& input) {
  if (input.empty()) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return "";
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, out.data(), size, nullptr, nullptr);
  return out;
}

std::wstring trim(const std::wstring& s) {
  const auto isSpace = [](wchar_t c) { return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n'; };
  size_t left = 0;
  while (left < s.size() && isSpace(s[left])) left++;
  size_t right = s.size();
  while (right > left && isSpace(s[right - 1])) right--;
  return s.substr(left, right - left);
}

bool parseBool(const std::wstring& s, bool fallback) {
  const std::wstring t = trim(s);
  if (t == L"true" || t == L"1" || t == L"TRUE") return true;
  if (t == L"false" || t == L"0" || t == L"FALSE") return false;
  return fallback;
}

int parseInt(const std::wstring& s, int fallback) {
  try {
    return std::stoi(std::wstring(trim(s)));
  } catch (...) {
    return fallback;
  }
}

std::vector<std::wstring> split(const std::wstring& s, wchar_t ch) {
  std::vector<std::wstring> out;
  std::wstring cur;
  for (wchar_t c : s) {
    if (c == ch) {
      out.push_back(cur);
      cur.clear();
    } else {
      cur.push_back(c);
    }
  }
  out.push_back(cur);
  return out;
}

} // namespace

bool AppSettings::isValid(std::string& missingField) const {
  struct Required {
    const char* value;
    const char* name;
  };

  const Required reqs[] = {
    { volcAppKey.c_str(), "VOLC_APP_KEY" },
    { volcAccessKey.c_str(), "VOLC_ACCESS_KEY" },
    { tosRegion.c_str(), "TOS_REGION" },
    { tosEndpoint.c_str(), "TOS_ENDPOINT" },
    { tosBucket.c_str(), "TOS_BUCKET" },
    { tosAK.c_str(), "TOS_AK" },
    { tosSK.c_str(), "TOS_SK" },
  };

  for (const auto& r : reqs) {
    if (!r.value || std::string(r.value).empty()) {
      missingField = r.name;
      return false;
    }
  }
  return true;
}

std::wstring getSettingsFilePath() {
  PWSTR appData = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &appData))) {
    return L"settings.env";
  }

  std::wstring root(appData);
  CoTaskMemFree(appData);

  const std::wstring dir = root + L"\\DoubaoMinutesWinCpp";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\settings.env";
}

AppSettings loadSettings() {
  AppSettings s;
  const std::wstring path = getSettingsFilePath();

  std::ifstream in(path);
  if (!in.is_open()) return s;

  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    const auto pos = line.find('=');
    if (pos == std::string::npos) continue;

    const std::wstring key = trim(utf8ToWide(line.substr(0, pos)));
    const std::wstring val = trim(utf8ToWide(line.substr(pos + 1)));

    if (key == L"VOLC_APP_KEY") s.volcAppKey = wideToUtf8(val);
    else if (key == L"VOLC_ACCESS_KEY") s.volcAccessKey = wideToUtf8(val);
    else if (key == L"VOLC_RESOURCE_ID") s.volcResourceId = wideToUtf8(val);
    else if (key == L"TOS_REGION") s.tosRegion = wideToUtf8(val);
    else if (key == L"TOS_ENDPOINT") s.tosEndpoint = wideToUtf8(val);
    else if (key == L"TOS_BUCKET") s.tosBucket = wideToUtf8(val);
    else if (key == L"TOS_AK") s.tosAK = wideToUtf8(val);
    else if (key == L"TOS_SK") s.tosSK = wideToUtf8(val);
    else if (key == L"TOS_STS_TOKEN") s.tosStsToken = wideToUtf8(val);
    else if (key == L"TOS_OBJECT_PREFIX") s.tosObjectPrefix = wideToUtf8(val);
    else if (key == L"TOS_SIGN_EXPIRES_SEC") s.tosSignExpiresSec = parseInt(val, s.tosSignExpiresSec);
    else if (key == L"POLL_INTERVAL_SEC") s.pollIntervalSec = parseInt(val, s.pollIntervalSec);
    else if (key == L"MAX_WAIT_MIN") s.maxWaitMin = parseInt(val, s.maxWaitMin);
    else if (key == L"MAX_CONCURRENT_JOBS") s.maxConcurrentJobs = parseInt(val, s.maxConcurrentJobs);
    else if (key == L"DELETE_TEMP_OBJECT") s.deleteTempObject = parseBool(val, s.deleteTempObject);
    else if (key == L"SAVE_RAW_JSON") s.saveRawJSON = parseBool(val, s.saveRawJSON);
    else if (key == L"TRANSLATION_ENABLE") s.translationEnabled = parseBool(val, s.translationEnabled);
    else if (key == L"TRANSLATION_SOURCE_LANG") s.translationSourceLang = wideToUtf8(val);
    else if (key == L"TRANSLATION_TARGET_LANG") s.translationTargetLang = wideToUtf8(val);
    else if (key == L"COMPLETION_SOUND_ENABLED") s.completionSoundEnabled = parseBool(val, s.completionSoundEnabled);
  }

  if (!s.translationEnabled) {
    s.translationSourceLang = "en_us";
    s.translationTargetLang = "zh_cn";
  }

  return s;
}

bool saveSettings(const AppSettings& s, std::wstring& errMsg) {
  const std::wstring path = getSettingsFilePath();
  std::ofstream out(path, std::ios::trunc);
  if (!out.is_open()) {
    errMsg = L"无法写入配置文件";
    return false;
  }

  auto put = [&out](const std::string& k, const std::string& v) {
    out << k << '=' << v << '\n';
  };
  auto putInt = [&out](const std::string& k, int v) {
    out << k << '=' << v << '\n';
  };
  auto putBool = [&out](const std::string& k, bool v) {
    out << k << '=' << (v ? "true" : "false") << '\n';
  };

  put("VOLC_APP_KEY", s.volcAppKey);
  put("VOLC_ACCESS_KEY", s.volcAccessKey);
  put("VOLC_RESOURCE_ID", s.volcResourceId);

  put("TOS_REGION", s.tosRegion);
  put("TOS_ENDPOINT", s.tosEndpoint);
  put("TOS_BUCKET", s.tosBucket);
  put("TOS_AK", s.tosAK);
  put("TOS_SK", s.tosSK);
  put("TOS_STS_TOKEN", s.tosStsToken);
  put("TOS_OBJECT_PREFIX", s.tosObjectPrefix);

  putInt("TOS_SIGN_EXPIRES_SEC", s.tosSignExpiresSec);
  putInt("POLL_INTERVAL_SEC", s.pollIntervalSec);
  putInt("MAX_WAIT_MIN", s.maxWaitMin);
  putInt("MAX_CONCURRENT_JOBS", s.maxConcurrentJobs);

  putBool("DELETE_TEMP_OBJECT", s.deleteTempObject);
  putBool("SAVE_RAW_JSON", s.saveRawJSON);
  putBool("TRANSLATION_ENABLE", s.translationEnabled);
  put("TRANSLATION_SOURCE_LANG", s.translationSourceLang);
  put("TRANSLATION_TARGET_LANG", s.translationTargetLang);
  putBool("COMPLETION_SOUND_ENABLED", s.completionSoundEnabled);

  out.flush();
  if (!out.good()) {
    errMsg = L"配置写入失败";
    return false;
  }
  return true;
}

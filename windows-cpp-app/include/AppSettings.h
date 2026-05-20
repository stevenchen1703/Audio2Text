#pragma once

#include <string>

struct AppSettings {
  std::string volcAppKey;
  std::string volcAccessKey;
  std::string volcResourceId = "volc.lark.minutes";

  std::string tosRegion = "cn-beijing";
  std::string tosEndpoint = "tos-cn-beijing.volces.com";
  std::string tosBucket;
  std::string tosAK;
  std::string tosSK;
  std::string tosStsToken;

  std::string tosObjectPrefix = "audio2txt/";
  int tosSignExpiresSec = 14400;
  int pollIntervalSec = 30;
  int maxWaitMin = 120;
  int maxConcurrentJobs = 10;

  bool deleteTempObject = true;
  bool saveRawJSON = false;
  bool translationEnabled = false;
  bool completionSoundEnabled = true;

  std::string translationSourceLang = "en_us";
  std::string translationTargetLang = "zh_cn";

  bool isValid(std::string& missingField) const;
};

std::wstring getSettingsFilePath();
AppSettings loadSettings();
bool saveSettings(const AppSettings& settings, std::wstring& errMsg);

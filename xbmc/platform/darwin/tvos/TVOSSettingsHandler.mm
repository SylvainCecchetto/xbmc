/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "TVOSSettingsHandler.h"

#include "ServiceBroker.h"
#include "settings/Settings.h"
#include "settings/SettingsComponent.h"
#include "settings/lib/Setting.h"
#include "threads/Atomics.h"

#import "platform/darwin/tvos/XBMCController.h"
#import "platform/darwin/tvos/input/LibInputHandler.h"
#import "platform/darwin/tvos/input/LibInputSettings.h"

#import "system.h"

static std::atomic_flag sg_singleton_lock_variable = ATOMIC_FLAG_INIT;
CTVOSInputSettings* CTVOSInputSettings::m_instance = nullptr;

CTVOSInputSettings& CTVOSInputSettings::GetInstance()
{
  CAtomicSpinLock lock(sg_singleton_lock_variable);
  if (!m_instance)
    m_instance = new CTVOSInputSettings();

  return *m_instance;
}

void CTVOSInputSettings::Initialize()
{
  bool idleTimer = CServiceBroker::GetSettingsComponent()->GetSettings()->GetBool(
      CSettings::SETTING_INPUT_SIRIREMOTEIDLETIMER);
  [g_xbmcController.inputHandler.inputSettings setSiriRemoteIdleTimer:idleTimer];
  int idleTime = CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
      CSettings::SETTING_INPUT_SIRIREMOTEIDLETIME);
  [g_xbmcController.inputHandler.inputSettings setSiriRemoteIdleTime:idleTime];
  int panHorizontalSensitivity = CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
      CSettings::SETTING_INPUT_SIRIREMOTEHORIZONTALSENSITIVITY);
  g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSensitivity = panHorizontalSensitivity;
  int panVerticalSensitivity = CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
      CSettings::SETTING_INPUT_SIRIREMOTEVERTICALSENSITIVITY);
  g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSensitivity = panVerticalSensitivity;
  int horizontalSwipeMinVelocity = CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
      CSettings::SETTING_INPUT_SIRIREMOTEHORIZONTALSWIPEMINVELOCITY);
  g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSwipeMinVelocity = horizontalSwipeMinVelocity;
  int verticalSwipeMinVelocity = CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
      CSettings::SETTING_INPUT_SIRIREMOTEVERTICALSWIPEMINVELOCITY);
  g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSwipeMinVelocity = verticalSwipeMinVelocity;
}

void CTVOSInputSettings::OnSettingChanged(const std::shared_ptr<const CSetting>& setting)
{
  if (setting == nullptr)
    return;

  const std::string& settingId = setting->GetId();
  if (settingId == CSettings::SETTING_INPUT_SIRIREMOTEIDLETIMER)
  {
    bool idleTimer = std::dynamic_pointer_cast<const CSettingBool>(setting)->GetValue();
    [g_xbmcController.inputHandler.inputSettings setSiriRemoteIdleTimer:idleTimer];
  }
  else if (settingId == CSettings::SETTING_INPUT_SIRIREMOTEIDLETIME)
  {
    int idleTime = std::dynamic_pointer_cast<const CSettingInt>(setting)->GetValue();
    [g_xbmcController.inputHandler.inputSettings setSiriRemoteIdleTime:idleTime];
  }
  else if (settingId == CSettings::SETTING_INPUT_SIRIREMOTEHORIZONTALSENSITIVITY)
  {
    int panHorizontalSensitivity = std::dynamic_pointer_cast<const CSettingInt>(setting)->GetValue();
    g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSensitivity = panHorizontalSensitivity;
  }
  else if (settingId == CSettings::SETTING_INPUT_SIRIREMOTEVERTICALSENSITIVITY)
  {
    int panVerticalSensitivity = std::dynamic_pointer_cast<const CSettingInt>(setting)->GetValue();
    g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSensitivity = panVerticalSensitivity;
  }
  else if (settingId == CSettings::SETTING_INPUT_SIRIREMOTEHORIZONTALSWIPEMINVELOCITY)
  {
    int horizontalSwipeMinVelocity = std::dynamic_pointer_cast<const CSettingInt>(setting)->GetValue();
    g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSwipeMinVelocity = horizontalSwipeMinVelocity;
  }
  else if (settingId == CSettings::SETTING_INPUT_SIRIREMOTEVERTICALSWIPEMINVELOCITY)
  {
    int verticalSwipeMinVelocity = std::dynamic_pointer_cast<const CSettingInt>(setting)->GetValue();
    g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSwipeMinVelocity = verticalSwipeMinVelocity;
  }
}

/*
 *  Copyright (C) 2012-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#include "TVOSPowerSyscall.h"

#include "utils/log.h"

IPowerSyscall* CTVOSPowerSyscall::CreateInstance()
{
  return new CTVOSPowerSyscall();
}

void CTVOSPowerSyscall::Register()
{
  IPowerSyscall::RegisterPowerSyscall(CTVOSPowerSyscall::CreateInstance);
}

bool CTVOSPowerSyscall::PumpPowerEvents(IPowerEventsCallback *callback)
{
  switch (m_state)
  {
    case SUSPENDED:
      callback->OnSleep();
      CLog::Log(LOGINFO, "%s: OnSleep called", __FUNCTION__);
      break;
    case RESUMED:
      callback->OnWake();
      CLog::Log(LOGINFO, "%s: OnWake called", __FUNCTION__);
      break;
    default:
      return false;
  }
  m_state = REPORTED;
  return true;
}

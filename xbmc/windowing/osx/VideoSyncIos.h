/*
 *  Copyright (C) 2015-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#pragma once

#include "windowing/VideoSync.h"
#include "guilib/DispResource.h"

// @todo create common parent class/interface, also update xbmc/windowing/osx/CMakeLists.txt
#if defined(TARGET_DARWIN_IOS)
#define WIN_SYSTEM_CLASS CWinSystemIOS
#elif defined(TARGET_DARWIN_TVOS)
#define WIN_SYSTEM_CLASS CWinSystemTVOS
#endif
class WIN_SYSTEM_CLASS;

class CVideoSyncIos : public CVideoSync, IDispResource
{
public:
  CVideoSyncIos(void *clock, WIN_SYSTEM_CLASS &winSystem) :
    CVideoSync(clock), m_winSystem(winSystem) {}

  // CVideoSync interface
  virtual bool Setup(PUPDATECLOCK func) override;
  virtual void Run(CEvent& stopEvent) override;
  virtual void Cleanup() override;
  virtual float GetFps() override;

  // IDispResource interface
  virtual void OnResetDisplay() override;

  // used in the displaylink callback
  void IosVblankHandler();

private:
  // CVideoSyncDarwin interface
  virtual bool InitDisplayLink();
  virtual void DeinitDisplayLink();

  int64_t m_LastVBlankTime = 0;  //timestamp of the last vblank, used for calculating how many vblanks happened
  CEvent m_abortEvent;
  WIN_SYSTEM_CLASS &m_winSystem;
};


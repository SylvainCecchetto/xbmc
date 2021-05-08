/*
 *  Copyright (C) 2019- Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "LibInputTouch.h"

#include "Application.h"
#include "ServiceBroker.h"
#include "guilib/GUIComponent.h"
#include "guilib/GUIWindowManager.h"
#include "utils/log.h"

#import "platform/darwin/tvos/TVOSEAGLView.h"
#import "platform/darwin/tvos/XBMCController.h"
#import "platform/darwin/tvos/input/LibInputHandler.h"
#import "platform/darwin/tvos/input/LibInputRemote.h"
#import "platform/darwin/tvos/input/LibInputSettings.h"

#include <tuple>

#import <UIKit/UIKit.h>

@class XBMCController;

@implementation TVOSLibInputTouch

#pragma mark - gesture methods

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)otherGestureRecognizer
{
  //CLog::Log(LOGDEBUG, "gestureRecognizer: shouldRecognizeSimultaneouslyWithGestureRecognizer");
  return YES;
}

// called before any press or touch event
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer shouldReceiveEvent:(nonnull UIEvent *)event
{
  // ignore any press or gesture before we are up and running
  if (!g_xbmcController.appAlive)
    return NO;
  return YES;
}

// called before pressesBegan:withEvent: is called on the gesture recognizer
// for a new press. return NO to prevent the gesture recognizer from seeing this press
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gestureRecognizer shouldReceivePress:(UIPress*)press
{
  CLog::Log(LOGDEBUG, "gestureRecognizer: shouldReceivePress");
  BOOL handled = YES;
  switch (press.type)
  {
    // single press key, but also detect hold and back to tvos.
    case UIPressTypeMenu:
      // menu is special.
      //  a) if at our home view, should return to atv home screen.
      //  b) if not, let it pass to us.
      if (CServiceBroker::GetGUI()->GetWindowManager().GetActiveWindow() == WINDOW_HOME &&
          !CServiceBroker::GetGUI()->GetWindowManager().HasVisibleModalDialog() &&
          !g_application.GetAppPlayer().IsPlaying())
        handled = NO;
      break;

    // single press keys
    case UIPressTypeSelect:
    case UIPressTypePlayPause:
      break;

    // auto-repeat keys
    case UIPressTypeUpArrow:
    case UIPressTypeDownArrow:
    case UIPressTypeLeftArrow:
    case UIPressTypeRightArrow:
      break;

    default:
      handled = NO;
  }

  return handled;
}

- (void)createSwipeGestureRecognizers
{
  for (auto swipeDirection :
       {UISwipeGestureRecognizerDirectionLeft, UISwipeGestureRecognizerDirectionRight,
        UISwipeGestureRecognizerDirectionUp, UISwipeGestureRecognizerDirectionDown})
  {
    auto swipeRecognizer =
        [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
    swipeRecognizer.delaysTouchesBegan = NO;
    swipeRecognizer.direction = swipeDirection;
    swipeRecognizer.delegate = self;
    [g_xbmcController.glView addGestureRecognizer:swipeRecognizer];
  }
}

- (void)createPanGestureRecognizers
{
  // for pan gestures with one finger
  auto pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
  pan.delegate = self;
  [g_xbmcController.glView addGestureRecognizer:pan];
}

- (void)createTapGesturecognizers
{
  // tap side of siri remote pad
  for (auto t : {
         std::make_tuple(UIPressTypeUpArrow, @selector(tapUpArrowPressed:),
                         @selector(IRRemoteUpArrowPressed:)),
             std::make_tuple(UIPressTypeDownArrow, @selector(tapDownArrowPressed:),
                             @selector(IRRemoteDownArrowPressed:)),
             std::make_tuple(UIPressTypeLeftArrow, @selector(tapLeftArrowPressed:),
                             @selector(IRRemoteLeftArrowPressed:)),
             std::make_tuple(UIPressTypeRightArrow, @selector(tapRightArrowPressed:),
                             @selector(IRRemoteRightArrowPressed:))
       })
  {
    auto allowedPressTypes = @[ @(std::get<0>(t)) ];

    auto arrowRecognizer =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:std::get<1>(t)];
    arrowRecognizer.allowedPressTypes = allowedPressTypes;
    arrowRecognizer.delegate = self;
    [g_xbmcController.glView addGestureRecognizer:arrowRecognizer];

    // @todo doesn't seem to work
    // we need UILongPressGestureRecognizer here because it will give
    // UIGestureRecognizerStateBegan AND UIGestureRecognizerStateEnded
    // even if we hold down for a long time. UITapGestureRecognizer
    // will eat the ending on long holds and we never see it.
    auto longArrowRecognizer =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:std::get<2>(t)];
    longArrowRecognizer.allowedPressTypes = allowedPressTypes;
    longArrowRecognizer.minimumPressDuration = 0.01;
    longArrowRecognizer.delegate = self;
    [g_xbmcController.glView addGestureRecognizer:longArrowRecognizer];
  }
}

- (void)createPressGesturecognizers
{
  auto menuRecognizer =
      [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(menuPressed:)];
  menuRecognizer.allowedPressTypes = @[ @(UIPressTypeMenu) ];
  menuRecognizer.delegate = self;
  [g_xbmcController.glView addGestureRecognizer:menuRecognizer];

  auto playPauseTypes = @[ @(UIPressTypePlayPause) ];
  auto playPauseRecognizer =
      [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(playPausePressed:)];
  playPauseRecognizer.allowedPressTypes = playPauseTypes;
  playPauseRecognizer.delegate = self;
  [g_xbmcController.glView addGestureRecognizer:playPauseRecognizer];

  auto doublePlayPauseRecognizer =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(doublePlayPausePressed:)];
  doublePlayPauseRecognizer.allowedPressTypes = playPauseTypes;
  doublePlayPauseRecognizer.numberOfTapsRequired = 2;
  doublePlayPauseRecognizer.delegate = self;
  [g_xbmcController.glView.gestureRecognizers.lastObject
      requireGestureRecognizerToFail:doublePlayPauseRecognizer];
  [g_xbmcController.glView addGestureRecognizer:doublePlayPauseRecognizer];

  auto longPlayPauseRecognizer =
      [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(longPlayPausePressed:)];
  longPlayPauseRecognizer.allowedPressTypes = playPauseTypes;
  longPlayPauseRecognizer.delegate = self;
  [g_xbmcController.glView addGestureRecognizer:longPlayPauseRecognizer];

  auto selectTypes = @[ @(UIPressTypeSelect) ];
  auto longSelectRecognizer =
      [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                    action:@selector(SiriLongSelectHandler:)];
  longSelectRecognizer.allowedPressTypes = selectTypes;
  longSelectRecognizer.minimumPressDuration = 0.001;
  longSelectRecognizer.delegate = self;
  [g_xbmcController.glView addGestureRecognizer:longSelectRecognizer];

  auto selectRecognizer =
      [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(SiriSelectHandler:)];
  selectRecognizer.allowedPressTypes = selectTypes;
  selectRecognizer.delegate = self;
  [longSelectRecognizer requireGestureRecognizerToFail:selectRecognizer];
  [g_xbmcController.glView addGestureRecognizer:selectRecognizer];

  auto doubleSelectRecognizer =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(SiriDoubleSelectHandler:)];
  doubleSelectRecognizer.allowedPressTypes = selectTypes;
  doubleSelectRecognizer.numberOfTapsRequired = 2;
  doubleSelectRecognizer.delegate = self;
  [longSelectRecognizer requireGestureRecognizerToFail:doubleSelectRecognizer];
  [g_xbmcController.glView.gestureRecognizers.lastObject
      requireGestureRecognizerToFail:doubleSelectRecognizer];
  [g_xbmcController.glView addGestureRecognizer:doubleSelectRecognizer];
}

- (void)menuPressed:(UITapGestureRecognizer*)sender
{
  if (sender.state == UIGestureRecognizerStateEnded)
  {
    CLog::Log(LOGDEBUG, "Input: Siri remote menu press (id: 5)");
    [g_xbmcController.inputHandler sendButtonPressed:6];
    [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
  }
}

- (void)SiriLongSelectHandler:(UIGestureRecognizer*)sender
{
  if (sender.state == UIGestureRecognizerStateBegan)
  {
    CLog::Log(LOGDEBUG, "Input: Siri remote select long press (id: 7)");
    [g_xbmcController.inputHandler sendButtonPressed:7];
    [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
  }
}

- (void)SiriSelectHandler:(UITapGestureRecognizer*)sender
{
  if (sender.state == UIGestureRecognizerStateEnded)
  {
    CLog::Log(LOGDEBUG, "Input: Siri remote select press (id: 5)");
    [g_xbmcController.inputHandler sendButtonPressed:5];
    [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
  }
}

- (void)playPausePressed:(UITapGestureRecognizer*)sender
{
  if (sender.state == UIGestureRecognizerStateEnded)
  {
    CLog::Log(LOGDEBUG, "Input: Siri remote play/pause press (id: 12)");
    [g_xbmcController.inputHandler sendButtonPressed:12];
    [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
  }
}

- (void)longPlayPausePressed:(UILongPressGestureRecognizer*)sender
{
  // Fonctionne
  CLog::Log(LOGDEBUG, "Input: Siri remote play/pause long press, state: %ld", static_cast<long>(sender.state));
}

- (void)doublePlayPausePressed:(UITapGestureRecognizer*)sender
{
  // state is only UIGestureRecognizerStateBegan and UIGestureRecognizerStateEnded
  // Fonctionne
  CLog::Log(LOGDEBUG, "Input: Siri remote play/pause double press");
}

- (void)SiriDoubleSelectHandler:(UITapGestureRecognizer*)sender
{
  // Fonctionne
  CLog::Log(LOGDEBUG, "Input: Siri remote select double press");
}

#pragma mark - IR Arrows Pressed

- (IBAction)IRRemoteUpArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: IR remote up press");
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      [g_xbmcController.inputHandler.inputRemote startKeyPressTimer:1];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [g_xbmcController.inputHandler.inputRemote stopKeyPressTimer];
      break;
    default:
      break;
  }
}

- (IBAction)IRRemoteDownArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: IR remote press down (id: 2)");
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      [g_xbmcController.inputHandler.inputRemote startKeyPressTimer:2];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [g_xbmcController.inputHandler.inputRemote stopKeyPressTimer];
      break;
    default:
      break;
  }
}

- (IBAction)IRRemoteLeftArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: IR remote press left (id: 3)");
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      [g_xbmcController.inputHandler.inputRemote startKeyPressTimer:3];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [g_xbmcController.inputHandler.inputRemote stopKeyPressTimer];
      break;
    default:
      break;
  }
}

- (IBAction)IRRemoteRightArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: IR remote press right (id: 4)");
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
      [g_xbmcController.inputHandler.inputRemote startKeyPressTimer:4];
      break;
    case UIGestureRecognizerStateChanged:
      break;
    case UIGestureRecognizerStateEnded:
      [g_xbmcController.inputHandler.inputRemote stopKeyPressTimer];
      break;
    default:
      break;
  }
}

#pragma mark - Tap Arrows

- (IBAction)tapUpArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: Siri remote tap up (id: 1)");
  if (!g_xbmcController.inputHandler.inputRemote.siriRemoteIdleState)
    [g_xbmcController.inputHandler sendButtonPressed:1];

  [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
}

- (IBAction)tapDownArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: Siri remote tap down (id: 2)");
  if (!g_xbmcController.inputHandler.inputRemote.siriRemoteIdleState)
    [g_xbmcController.inputHandler sendButtonPressed:2];

  [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
}

- (IBAction)tapLeftArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: Siri remote tap left (id: 3)");
  if (!g_xbmcController.inputHandler.inputRemote.siriRemoteIdleState)
    [g_xbmcController.inputHandler sendButtonPressed:3];

  [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
}

- (IBAction)tapRightArrowPressed:(UIGestureRecognizer*)sender
{
  CLog::Log(LOGDEBUG, "Input: Siri remote tap right (id: 4)");
  if (!g_xbmcController.inputHandler.inputRemote.siriRemoteIdleState)
    [g_xbmcController.inputHandler sendButtonPressed:4];

  [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
}

#pragma mark - Pan

- (IBAction)handlePan:(UIPanGestureRecognizer*)sender
{
  if (g_xbmcController.inputHandler.inputRemote.siriRemoteIdleState)
  {
    [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
    return;
  }
  
  CGPoint translation = [sender translationInView:sender.view];
  CGPoint velocity = [sender velocityInView:sender.view];
  UIPanGestureRecognizerDirection direction = [self getPanDirection:velocity];
  
//  CLog::Log(LOGDEBUG, "Input: pan (point: (%f,%f), velocity: (%f,%f))", translation.x, translation.y, velocity.x, velocity.y);

  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
    {
      m_lastGesturePoint = translation;
      break;
    }
    case UIGestureRecognizerStateChanged:
    {
      int keyId = 0;
      switch (direction)
      {
        case UIPanGestureRecognizerDirectionUp:
        {
          if(fabs(m_lastGesturePoint.y - translation.y) > g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSensitivity)
          {
            CLog::Log(LOGDEBUG, "Input: Siri remote pan up (id: 20) %i", g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSensitivity);
            keyId = 20;
          }
          break;
        }
        case UIPanGestureRecognizerDirectionDown:
        {
          if(fabs(m_lastGesturePoint.y - translation.y) > g_xbmcController.inputHandler.inputSettings.siriRemoteVerticalSensitivity)
          {
            CLog::Log(LOGDEBUG, "Input: Siri remote pan down (id: 21)");
            keyId = 21;
          }
          break;
        }
        case UIPanGestureRecognizerDirectionLeft:
        {
          if(fabs(m_lastGesturePoint.x - translation.x) > g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSensitivity)
          {
            CLog::Log(LOGDEBUG, "Input: Siri remote pan left (id: 22) %i", g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSensitivity);
            keyId = 22;
          }
          break;
        }
        case UIPanGestureRecognizerDirectionRight:
        {
          if(fabs(m_lastGesturePoint.x - translation.x) > g_xbmcController.inputHandler.inputSettings.siriRemoteHorizontalSensitivity)
          {
            CLog::Log(LOGDEBUG, "Input: Siri remote pan right (id: 23)");
            keyId = 23;
          }
          break;
        }
        default:
        {
            break;
        }
      }
      if (keyId != 0)
      {
        m_lastGesturePoint = translation;
        [g_xbmcController.inputHandler sendButtonPressed:keyId];
      }
      break;
    }
    // We check the velocity at the end of the pan gesture to simulate the swipe gesture
    case UIGestureRecognizerStateEnded:
      break;
    default:
      break;
  }
  [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
}

- (IBAction)handleSwipe:(UISwipeGestureRecognizer*)sender
{
  if (g_xbmcController.inputHandler.inputRemote.siriRemoteIdleState)
  {
    [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
    return;
  }

  int keyId = 0;
  switch (sender.direction)
  {
    case UISwipeGestureRecognizerDirectionUp:
    {
      CLog::Log(LOGDEBUG, "Input: Siri remote swipe up (id: 8)");
      keyId = 8;
      break;
    }
    case UISwipeGestureRecognizerDirectionDown:
    {
      CLog::Log(LOGDEBUG, "Input: Siri remote swipe down (id: 9)");
      keyId = 9;
      break;
    }
    case UISwipeGestureRecognizerDirectionLeft:
    {
      CLog::Log(LOGDEBUG, "Input: Siri remote swipe left (id: 10)");
      keyId = 10;
      break;
    }
    case UISwipeGestureRecognizerDirectionRight:
    {
      CLog::Log(LOGDEBUG, "Input: Siri remote swipe right (id: 11)");
      keyId = 11;
      break;
    }
    default:
      break;
  }
  [g_xbmcController.inputHandler sendButtonPressed:keyId];
  [g_xbmcController.inputHandler.inputRemote startSiriRemoteIdleTimer];
}

- (UIPanGestureRecognizerDirection)getPanDirection:(CGPoint)velocity
{
  bool isVerticalGesture = fabs(velocity.y) > fabs(velocity.x);

  if (isVerticalGesture)
  {
    if (velocity.y > 0)
      return UIPanGestureRecognizerDirectionDown;
    else
      return UIPanGestureRecognizerDirectionUp;
  }
  else
  {
    if (velocity.x > 0)
      return UIPanGestureRecognizerDirectionRight;
    else
      return UIPanGestureRecognizerDirectionLeft;
  }
}

@end

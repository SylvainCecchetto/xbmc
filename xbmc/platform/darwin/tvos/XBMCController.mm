/*
 *  Copyright (C) 2010-2018 Team Kodi
 *  This file is part of Kodi - https://kodi.tv
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSES/README.md for more information.
 */

#import "platform/darwin/tvos/XBMCController.h"

#import "AppParamParser.h"
#import "Application.h"
#import "ServiceBroker.h"
#import "cores/AudioEngine/Interfaces/AE.h"
#import "guilib/GUIComponent.h"
#import "guilib/GUIWindowManager.h"
#import "input/ButtonTranslator.h"
#import "input/CustomControllerTranslator.h"
#import "input/InputManager.h"
#import "input/Key.h"
#import "interfaces/AnnouncementManager.h"
#import "messaging/ApplicationMessenger.h"
#import "network/NetworkServices.h"
#import "platform/xbmc.h"
#import "settings/AdvancedSettings.h"
#import "utils/log.h"
#import "windowing/tvos/WinEventsTVOS.h"
#import "windowing/tvos/WinSystemTVOS.h"

#import "platform/darwin/FocusEngineHandler.h"
#import "platform/darwin/NSLogDebugHelpers.h"
#import "platform/darwin/ios-common/AnnounceReceiver.h"
#import "platform/darwin/ios-common/IOSKeyboardView.h"
#import "platform/darwin/tvos/FocusLayerView.h"
#import "platform/darwin/tvos/FocusLayerViewPlayerProgress.h"
#import "platform/darwin/tvos/TVOSEAGLView.h"
#import "platform/darwin/tvos/TVOSTopShelf.h"
#import "platform/darwin/tvos/XBMCApplication.h"

#import <MediaPlayer/MPMediaItem.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#import <GameController/GameController.h>


#import "system.h"

#if __TVOS_11_2
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>

@interface AVDisplayCriteria ()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end
#else
@interface AVDisplayCriteria : NSObject <NSCopying>
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

@interface AVDisplayManager : NSObject
@property(nonatomic, readonly, getter=isDisplayModeSwitchInProgress)
    BOOL displayModeSwitchInProgress;
@property(nonatomic, copy) AVDisplayCriteria* preferredDisplayCriteria;
@end

@interface UIWindow (AVAdditions)
@property(nonatomic, readonly) AVDisplayManager* avDisplayManager;
@end
#endif

// these MUST match those in system/keymaps/customcontroller.SiriRemote.xml
typedef enum SiriRemoteTypes
{
  SiriRemote_UpTap = 1,
  SiriRemote_DownTap = 2,
  SiriRemote_LeftTap = 3,
  SiriRemote_RightTap = 4,
  SiriRemote_CenterClick = 5,
  SiriRemote_MenuClick = 6,
  SiriRemote_CenterHold = 7,
  SiriRemote_UpSwipe = 8,
  SiriRemote_DownSwipe = 9,
  SiriRemote_LeftSwipe = 10,
  SiriRemote_RightSwipe = 11,
  SiriRemote_PausePlayClick = 12,
  SiriRemote_IR_Play = 13,
  SiriRemote_IR_Pause= 14,
  SiriRemote_IR_Stop = 15,
  SiriRemote_IR_NextTrack = 16,
  SiriRemote_IR_PreviousTrack = 17,
  SiriRemote_IR_FastForward = 18,
  SiriRemote_IR_Rewind = 19,
  SiriRemote_MenuClickAtHome = 20,
  SiriRemote_UpScroll = 21,
  SiriRemote_DownScroll = 22,
  SiriRemote_PageUp = 23,
  SiriRemote_PageDown = 24
} SiriRemoteTypes;

using namespace KODI::MESSAGING;

XBMCController* g_xbmcController;

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - XBMCController interface
//--------------------------------------------------------------
//--------------------------------------------------------------

@interface XBMCController ()
@property(strong, nonatomic) NSTimer* pressAutoRepeatTimer;
@property(strong, nonatomic) NSTimer* remoteIdleTimer;
@property(nonatomic, strong) CADisplayLink* displayLink;
@property(nonatomic, assign) float displayRate;
@property (strong, nonatomic) UIPanGestureRecognizer *panRecognizer;
@property (strong, nonatomic) UITapGestureRecognizer *doubleTapRecognizer;
@property (strong, nonatomic) UITapGestureRecognizer *tripleTapRecognizer;
@property (nonatomic, nullable) FocusLayerView *focusView;
@property (nonatomic, nullable) FocusLayerView *focusViewLeft;
@property (nonatomic, nullable) FocusLayerView *focusViewRight;
@property (nonatomic, nullable) FocusLayerView *focusViewTop;
@property (nonatomic, nullable) FocusLayerView *focusViewBottom;
@property (nonatomic, assign) FocusLayer focusLayer;
@property (strong, nonatomic) NSTimer *focusIdleTimer;
@property (strong) GCController* gcController;
@end

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - XBMCController implementation
//--------------------------------------------------------------
//--------------------------------------------------------------

@implementation XBMCController

@synthesize m_lastGesturePoint;
@synthesize m_screenScale;
@synthesize m_screenIdx;
@synthesize m_screensize;
@synthesize m_nowPlayingInfo;
@synthesize m_directionOverride;
@synthesize m_direction;
@synthesize m_currentKey;
@synthesize m_clickResetPan;
@synthesize m_mimicAppleSiri;
@synthesize m_remoteIdleState;
@synthesize m_remoteIdleTimeout;
@synthesize m_shouldRemoteIdle;
@synthesize m_RemoteOSDSwipes;
@synthesize m_touchDirection;
@synthesize m_touchBeginSignaled;

#define NEW_REMOTE_HANDLING 0 // TO DELETE?

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - XBMCController methods
//--------------------------------------------------------------
//--------------------------------------------------------------

- (id)initWithFrame:(CGRect)frame withScreen:(UIScreen*)screen
{
  m_screenIdx = 0;
  self = [super init];
  if (!self)
    return nil;
  
  m_pause = FALSE;
  m_appAlive = FALSE;
  m_animating = FALSE;
  
  m_isPlayingBeforeInactive = NO;
  m_bgTask = UIBackgroundTaskInvalid;
  
  m_window = [[UIWindow alloc] initWithFrame:frame];
  [m_window setRootViewController:self];
  m_window.screen = screen;
  m_window.backgroundColor = [UIColor blackColor];
  // Turn off autoresizing
  m_window.autoresizingMask = 0;
  m_window.autoresizesSubviews = NO;
  
  [self enableScreenSaver];
  
  [m_window makeKeyAndVisible];
  g_xbmcController = self;
  
  self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                 selector:@selector(displayLinkTick:)];
  // we want the native cadence of the display hardware.
  self.displayLink.preferredFramesPerSecond = 0;
  [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
  
  return self;
}

//--------------------------------------------------------------
- (void)dealloc
{
  // stop background task (if running)
  [self disableBackGroundTask];
  
  [self stopAnimation];
}

//--------------------------------------------------------------
- (void)loadView
{
  self.view = [[UIView alloc] initWithFrame:m_window.bounds];
  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.view.autoresizesSubviews = YES;
  
  m_glView = [[TVOSEAGLView alloc] initWithFrame:self.view.bounds withScreen:[UIScreen mainScreen]];
  
  // Check if screen is Retina
  m_screenScale = [m_glView getScreenScale:[UIScreen mainScreen]];
  [self.view addSubview:m_glView];
  
  CGRect focusRect = CGRectMake(0, 0, m_glView.bounds.size.width, m_glView.bounds.size.height);
  // virtual views, these are outside focusView (display bounds)
  // and used to detect up/down/right/left focus movements for pop/slide out views
  // we trap/cancel the focus move in shouldUpdateFocusInContext
  // if the focused core control can do the move, it will and we will get a focus update
  // from core which we then use to adjust focus in didUpdateFocusInContext.
  // That's the theory anyway :)
  CGRect focusRectTop = focusRect;
  focusRectTop.origin.y -= 200;
  focusRectTop.size.height = 200;
  self.focusViewTop = [[FocusLayerView alloc] initWithFrame:focusRectTop];
  [self.focusViewTop setFocusable:true];
  [self.focusViewTop setViewVisible:false];
  
  CGRect focusRectLeft = focusRect;
  focusRectLeft.origin.x -= 200;
  focusRectLeft.size.width = 200;
  self.focusViewLeft = [[FocusLayerView alloc] initWithFrame:focusRectLeft];
  [self.focusViewLeft setFocusable:true];
  [self.focusViewLeft setViewVisible:false];
  
  CGRect focusRectRight = focusRect;
  focusRectRight.origin.x += focusRect.size.width;
  focusRectRight.size.width = 200;
  self.focusViewRight = [[FocusLayerView alloc] initWithFrame:focusRectRight];
  [self.focusViewRight setFocusable:true];
  [self.focusViewRight setViewVisible:false];
  
  CGRect focusRectBottom = focusRect;
  focusRectBottom.origin.y += focusRect.size.height;
  focusRectBottom.size.height = 200;
  self.focusViewBottom = [[FocusLayerView alloc] initWithFrame:focusRectBottom];
  [self.focusViewBottom setFocusable:true];
  [self.focusViewBottom setViewVisible:false];
  
  self.focusView = [[FocusLayerView alloc] initWithFrame:focusRect];
  [self.focusView setFocusable:true];
  [self.focusView setViewVisible:false];
  // focus layer lives above m_glView
  [self.view insertSubview:self.focusView aboveSubview:m_glView];
  
  [self.focusView addSubview:self.focusViewTop];
  [self.focusView addSubview:self.focusViewLeft];
  [self.focusView addSubview:self.focusViewRight];
  [self.focusView addSubview:self.focusViewBottom];
  
  //[self createSwipeGestureRecognizers];
  //[self createPanGestureRecognizers];
  //[self createPressGesturecognizers];
  //[self createTapGesturecognizers];
  
  if (__builtin_available(tvOS 11.2, *))
  {
    if ([m_window respondsToSelector:@selector(avDisplayManager)])
    {
      auto avDisplayManager = [m_window avDisplayManager];
      [avDisplayManager addObserver:self
                         forKeyPath:@"displayModeSwitchInProgress"
                            options:NSKeyValueObservingOptionNew
                            context:nullptr];
    }
  }
}

//--------------------------------------------------------------
- (void)viewDidLoad
{
  [super viewDidLoad];
  
  // safe time to update screensize, loadView is too early
  m_screensize.width  = m_glView.bounds.size.width  * m_screenScale;
  m_screensize.height = m_glView.bounds.size.height * m_screenScale;
  
  [self createSiriPressGesturecognizers];
  [self createSiriSwipeGestureRecognizers];
  [self createSiriPanGestureRecognizers];
  [self createSiriTapGestureRecognizers];
  //FIXME: [self createCustomControlCenter];
  [self initGameController];
  
  if (__builtin_available(tvOS 11.2, *))
  {
    if ([m_window respondsToSelector:@selector(avDisplayManager)])
    {
      auto avDisplayManager = [m_window avDisplayManager];
      [avDisplayManager addObserver:self forKeyPath:@"displayModeSwitchInProgress" options:NSKeyValueObservingOptionNew context:nullptr];
    }
  }
  //g_application.SetVolume(100, true);
}

//--------------------------------------------------------------
- (void)viewWillAppear:(BOOL)animated
{
  [self resumeAnimation];
  [super viewWillAppear:animated];
}

//--------------------------------------------------------------
- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
  [[UIApplication sharedApplication]
   beginReceivingRemoteControlEvents]; // @todo MPRemoteCommandCenter
}

//--------------------------------------------------------------
- (void)viewWillDisappear:(BOOL)animated
{
  [self pauseAnimation];
  [super viewWillDisappear:animated];
  if (__builtin_available(tvOS 11.2, *))
  {
    if ([m_window respondsToSelector:@selector(avDisplayManager)])
    {
      auto avDisplayManager = [m_window avDisplayManager];
      [avDisplayManager removeObserver:self forKeyPath:@"displayModeSwitchInProgress"];
    }
  }
}

//--------------------------------------------------------------
- (void)viewDidUnload
{
  [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
  [self resignFirstResponder];
  [super viewDidUnload];
}

//--------------------------------------------------------------
- (UIView*)inputView
{
  // override our input view to an empty view
  // this prevents the on screen keyboard
  // which would be shown whenever this UIResponder
  // becomes the first responder (which is always the case!)
  // caused by implementing the UIKeyInput protocol
  return [[UIView alloc] initWithFrame:CGRectZero];
}

//--------------------------------------------------------------
- (BOOL)canBecomeFirstResponder
{
  return YES;
}

//--------------------------------------------------------------
- (void)setFramebuffer
{
  if (!m_pause)
    [m_glView setFramebuffer];
}

//--------------------------------------------------------------
- (bool)presentFramebuffer
{
  if (!m_pause)
    return [m_glView presentFramebuffer];
  else
    return FALSE;
}

//--------------------------------------------------------------
- (CGSize)getScreenSize
{
  dispatch_sync(dispatch_get_main_queue(), ^{
    m_screensize.width = m_glView.bounds.size.width * m_screenScale;
    m_screensize.height = m_glView.bounds.size.height * m_screenScale;
  });
  return m_screensize;
}

//--------------------------------------------------------------
- (void)didReceiveMemoryWarning
{
  PRINT_SIGNATURE();
  // Releases the view if it doesn't have a superview.
  [super didReceiveMemoryWarning];
  // Release any cached data, images, etc. that aren't in use.
}

//--------------------------------------------------------------
- (void)enableBackGroundTask
{
  if (m_bgTask != UIBackgroundTaskInvalid)
  {
    [[UIApplication sharedApplication] endBackgroundTask:m_bgTask];
    m_bgTask = UIBackgroundTaskInvalid;
  }
  LOG(@"%s: beginBackgroundTask", __PRETTY_FUNCTION__);
  // we have to alloc the background task for keep network working after screen lock and dark.
  m_bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
}

//--------------------------------------------------------------
- (void)disableBackGroundTask
{
  if (m_bgTask != UIBackgroundTaskInvalid)
  {
    LOG(@"%s: endBackgroundTask", __PRETTY_FUNCTION__);
    [[UIApplication sharedApplication] endBackgroundTask:m_bgTask];
    m_bgTask = UIBackgroundTaskInvalid;
  }
}

//--------------------------------------------------------------
- (void)disableSystemSleep
{
}

//--------------------------------------------------------------
- (void)enableSystemSleep
{
}

//--------------------------------------------------------------
- (void)disableScreenSaver
{
  m_disableIdleTimer = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
  });
}

//--------------------------------------------------------------
- (void)enableScreenSaver
{
  m_disableIdleTimer = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
  });
}

//--------------------------------------------------------------
- (bool)resetSystemIdleTimer
{
  // this is silly :)
  // when system screen saver kicks off, we switch to UIApplicationStateInactive, the only way
  // to get out of the screensaver is to call ourself to open an custom URL that is registered
  // in our Info.plist. The openURL method of UIApplication must be supported but we can just
  // reply NO and we get restored to UIApplicationStateActive.
  __block bool inActive = false;
  dispatch_async(dispatch_get_main_queue(), ^{
    inActive = [UIApplication sharedApplication].applicationState == UIApplicationStateInactive;
    if (inActive)
    {
      NSURL* url = [NSURL URLWithString:@"kodi://wakeup"];
      [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
  });
  return inActive;
}

//--------------------------------------------------------------
- (UIScreenMode*)preferredScreenMode:(UIScreen*)screen
{
  // tvOS only support one mode, the current one.
  return [screen currentMode];
}

//--------------------------------------------------------------
- (NSArray<UIScreenMode*>*)availableScreenModes:(UIScreen*)screen
{
  // tvOS only support one mode, the current one,
  // pass back an array with this inside.
  return @[ screen.currentMode ];
}

//--------------------------------------------------------------
- (bool)changeScreen:(unsigned int)screenIdx withMode:(UIScreenMode*)mode
{
  return true;
}

//--------------------------------------------------------------
- (void)enterForeground
{
  // stop background task (if running)
  [self disableBackGroundTask];
  
  [NSThread detachNewThreadSelector:@selector(enterForegroundDelayed:)
                           toTarget:self
                         withObject:nil];
}

//--------------------------------------------------------------
- (void)enterBackground
{
  // We have 5 seconds before the OS will force kill us for delaying too long.
  XbmcThreads::EndTime timer(4500);
  
  // this should not be required as we 'should' get becomeInactive before enterBackground
  if (g_application.GetAppPlayer().IsPlaying() && !g_application.GetAppPlayer().IsPaused())
  {
    m_isPlayingBeforeInactive = YES;
    CApplicationMessenger::GetInstance().SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }
  
  CWinSystemTVOS* winSystem = dynamic_cast<CWinSystemTVOS*>(CServiceBroker::GetWinSystem());
  winSystem->OnAppFocusChange(false);
  
  // Apple says to disable ZeroConfig when moving to background
  //! @todo
  //CNetworkServices::GetInstance().StopZeroconf();
  
  if (m_isPlayingBeforeInactive)
  {
    // if we were playing and have paused, then
    // enable a background task to keep the network alive
    [self enableBackGroundTask];
  }
  else
  {
    // if we are not playing/pause when going to background
    // close out network shares as we can get fully suspended.
    g_application.CloseNetworkShares();
  }
  
  // OnAppFocusChange triggers an AE suspend.
  // Wait for AE to suspend and delete the audio sink, this allows
  // AudioOutputUnitStop to complete and AVAudioSession to be set inactive.
  // Note that to user, we moved into background to user but we
  // are really waiting here for AE to suspend.
  //! @todo
  /*
   while (!CAEFactory::IsSuspended() && !timer.IsTimePast())
   usleep(250*1000);
   */
}

//--------------------------------------------------------------
- (void)enterForegroundDelayed:(id)arg
{
  // MCRuntimeLib_Initialized is only true if
  // we were running and got moved to background
  while (!g_application.IsInitialized())
    usleep(50 * 1000);
  
  CWinSystemTVOS* winSystem = dynamic_cast<CWinSystemTVOS*>(CServiceBroker::GetWinSystem());
  winSystem->OnAppFocusChange(true);
  
  // when we come back, restore playing if we were.
  if (m_isPlayingBeforeInactive)
  {
    CApplicationMessenger::GetInstance().SendMsg(TMSG_MEDIA_UNPAUSE);
    m_isPlayingBeforeInactive = NO;
  }
  // restart ZeroConfig (if stopped)
  //! @todo
  //CNetworkServices::GetInstance().StartZeroconf();
  
  // do not update if we are already updating
  if (!(g_application.IsVideoScanning() || g_application.IsMusicScanning()))
    g_application.UpdateLibraries();
  
  // this will fire only if we are already alive and have 'menu'ed out and back
  CServiceBroker::GetAnnouncementManager()->Announce(ANNOUNCEMENT::System, "xbmc", "OnWake");
  
  // this handles what to do if we got pushed
  // into foreground by a topshelf item select/play
  CTVOSTopShelf::GetInstance().RunTopShelf();
}

//--------------------------------------------------------------
- (void)becomeInactive
{
  // if we were interrupted, already paused here
  // else if user background us or lock screen, only pause video here, audio keep playing.
  if (g_application.GetAppPlayer().IsPlayingVideo() && !g_application.GetAppPlayer().IsPaused())
  {
    m_isPlayingBeforeInactive = YES;
    CApplicationMessenger::GetInstance().SendMsg(TMSG_MEDIA_PAUSE_IF_PLAYING);
  }
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - helper methods/routines
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)activateKeyboard:(UIView*)view
{
  [self.view addSubview:view];
  m_glView.userInteractionEnabled = NO;
}

//--------------------------------------------------------------
- (void)deactivateKeyboard:(UIView*)view
{
  [view removeFromSuperview];
  m_glView.userInteractionEnabled = YES;
  [self becomeFirstResponder];
}

//--------------------------------------------------------------
- (void)nativeKeyboardActive:(bool)active;
{
  m_nativeKeyboardActive = active;
}

//--------------------------------------------------------------
- (EAGLContext*)getEAGLContextObj
{
  return [m_glView getCurrentEAGLContext];
}

//--------------------------------------------------------------
- (bool)hasPlayerProgressScrubbing
{
  if (m_enableRemoteExpertMode)
    return false;
  
  if (!CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
    return false;
  
  if (g_application.GetAppPlayer().IsPlayingVideo() && !g_application.GetAppPlayer().CanSeek())
    return false;
  
  //FIXME: fixme
  /*
  CFileItem &fileItem = g_application.CurrentFileItem();
  if (URIUtils::IsLiveTV(fileItem.GetPath())
      ||  URIUtils::IsBluray(fileItem.GetPath())
      ||  fileItem.IsPVR()
      ||  fileItem.IsBDFile()
      ||  fileItem.IsDVD()
      ||  fileItem.IsDiscImage()
      ||  fileItem.IsDVDFile(false, true)
      ||  fileItem.IsDiscStub()
      ||  fileItem.IsPlayList())
    return false;
  
  if (fileItem.HasProperty("strm-based"))
  {
    if ([m_disableOSDExtensions containsObject:@".strm"])
      return false;
  }
  
  NSString *itemExt = [NSString stringWithUTF8String:URIUtils::GetExtension(fileItem.GetPath()).c_str()];
  if ([m_disableOSDExtensions containsObject:itemExt])
    return false;
   */
  
  return true;
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - runtime routines
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)pauseAnimation
{
  m_pause = TRUE;
  g_application.SetRenderGUI(false);
}

//--------------------------------------------------------------
- (void)resumeAnimation
{
  m_pause = FALSE;
  g_application.SetRenderGUI(true);
}

//--------------------------------------------------------------
- (void)startAnimation
{
  if (m_animating == NO && [m_glView getCurrentEAGLContext])
  {
    // kick off an animation thread
    m_animationThreadLock = [[NSConditionLock alloc] initWithCondition:FALSE];
    m_animationThread = [[NSThread alloc] initWithTarget:self
                                                selector:@selector(runAnimation:)
                                                  object:m_animationThreadLock];
    [m_animationThread start];
    m_animating = TRUE;
  }
}

//--------------------------------------------------------------
- (void)stopAnimation
{
  if (m_animating == NO && [m_glView getCurrentEAGLContext])
  {
    m_appAlive = FALSE;
    m_animating = FALSE;
    if (!g_application.m_bStop)
    {
      CApplicationMessenger::GetInstance().PostMsg(TMSG_QUIT);
    }
    
    CAnnounceReceiver::GetInstance()->DeInitialize();
    
    // wait for animation thread to die
    if ([m_animationThread isFinished] == NO)
      [m_animationThreadLock lockWhenCondition:TRUE];
  }
}

//--------------------------------------------------------------
int KODI_Run(bool renderGUI)
{
  int status = -1;
  
  CAppParamParser appParamParser; //! @todo : proper params
  if (!g_application.Create(appParamParser))
  {
    ELOG(@"ERROR: Unable to create application. Exiting");
    return status;
  }
  
  //this can't be set from CAdvancedSettings::Initialize()
  //because it will overwrite the loglevel set with the --debug flag
#ifdef _DEBUG
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevel = LOG_LEVEL_DEBUG;
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevelHint = LOG_LEVEL_DEBUG;
#else
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevel = LOG_LEVEL_NORMAL;
  CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevelHint = LOG_LEVEL_NORMAL;
#endif
  CLog::SetLogLevel(CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->m_logLevel);
  
  // not a failure if returns false, just means someone
  // did the init before us.
  if (!CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->Initialized())
  {
    //CServiceBroker::GetSettingsComponent()->GetAdvancedSettings()->Initialize();
    //! @todo
  }
  
  CAnnounceReceiver::GetInstance()->Initialize();
  
  if (renderGUI && !g_application.CreateGUI())
  {
    ELOG(@"ERROR: Unable to create GUI. Exiting");
    return status;
  }
  if (!g_application.Initialize())
  {
    ELOG(@"ERROR: Unable to Initialize. Exiting");
    return status;
  }
  
  try
  {
    status = g_application.Run(appParamParser);
  }
  catch (...)
  {
    ELOG(@"ERROR: Exception caught on main loop. Exiting");
    status = -1;
  }
  
  return status;
}

//--------------------------------------------------------------
- (void)runAnimation:(id)arg
{
  @autoreleasepool
  {
    [[NSThread currentThread] setName:@"XBMC_Run"];
    
    // signal the thread is alive
    NSConditionLock* myLock = arg;
    [myLock lock];
    
    // Prevent child processes from becoming zombies on exit
    // if not waited upon. See also Util::Command
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_NOCLDWAIT;
    sa.sa_handler = SIG_IGN;
    sigaction(SIGCHLD, &sa, NULL);
    
    setlocale(LC_NUMERIC, "C");
    
    int status = 0;
    try
    {
      // set up some Kodi specific relationships
      //    XBMC::Context run_context; //! @todo
      m_appAlive = TRUE;
      // start up with gui enabled
      status = KODI_Run(true);
      // we exited or died.
      g_application.SetRenderGUI(false);
    }
    catch (...)
    {
      m_appAlive = FALSE;
      ELOG(@"%sException caught on main loop status=%d. Exiting", __PRETTY_FUNCTION__, status);
    }
    
    // signal the thread is dead
    [myLock unlockWithCondition:TRUE];
    
    [self enableScreenSaver];
    [self enableSystemSleep];
    [self performSelectorOnMainThread:@selector(CallExit) withObject:nil waitUntilDone:NO];
  }
}

//--------------------------------------------------------------
- (void)CallExit
{
  exit(0);
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - AVDisplayLayer methods
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)insertVideoView:(UIView*)view
{
  [self.view insertSubview:view belowSubview:m_glView];
  [self.view setNeedsDisplay];
}

//--------------------------------------------------------------
- (void)removeVideoView:(UIView*)view
{
  [view removeFromSuperview];
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - display switching routines
//--------------------------------------------------------------
//--------------------------------------------------------------

- (float)getDisplayRate
{
  if (self.displayRate > 0)
    return self.displayRate;
  
  return 60.0;
}

//--------------------------------------------------------------
- (void)displayLinkTick:(CADisplayLink*)sender
{
  if (self.displayLink.duration > 0.0)
  {
    static float oldDisplayRate = 0.00;
    // we want fps, not duration in seconds.
    self.displayRate = 1.0 / self.displayLink.duration;
    if (self.displayRate != oldDisplayRate)
    {
      // track and log changes
      oldDisplayRate = self.displayRate;
      //CLog::Log(LOGDEBUG, "%s: displayRate = %f", __PRETTY_FUNCTION__, self.displayRate);
    }
  }
}

//--------------------------------------------------------------
- (void)displayRateSwitch:(float)refreshRate withDynamicRange:(int)dynamicRange
{
  if (CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
                                                                    CSettings::SETTING_VIDEOPLAYER_ADJUSTREFRESHRATE) != ADJUST_REFRESHRATE_OFF)
  {
    if (__builtin_available(tvOS 11.2, *))
    {
      // avDisplayManager is only in 11.2 beta4 so we need to also
      // trap out for older 11.2 betas. This can be changed once
      // tvOS 11.2 gets released.
      if ([m_window respondsToSelector:@selector(avDisplayManager)])
      {
        auto avDisplayManager = [m_window avDisplayManager];
        if (refreshRate > 0.0)
        {
          // initWithRefreshRate is private in 11.2 beta4 but apple
          // will move it public at some time.
          // videoDynamicRange values are based on watching
          // console log when forcing different values.
          // search for "Native Mode Requested" and pray :)
          // searches for "FBSDisplayConfiguration" and "currentMode" will show the actual
          // for example, currentMode = <FBSDisplayMode: 0x1c4298100; 1920x1080@2x (3840x2160/2) 24Hz p3 HDR10>
          // SDR == 0, 1
          // HDR == 2, 3
          // DoblyVision == 4
#if __TVOS_11_2
          auto displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:refreshRate
                                                              videoDynamicRange:dynamicRange];
#else
          std::string neveryyoumind = "AVDisplayCriteria";
          Class AVDisplayCriteriaClass =
          NSClassFromString([NSString stringWithUTF8String:neveryyoumind.c_str()]);
          AVDisplayCriteria* displayCriteria =
          [[AVDisplayCriteriaClass alloc] initWithRefreshRate:refreshRate
                                            videoDynamicRange:dynamicRange];
#endif
          // setting preferredDisplayCriteria will trigger a display rate switch
          avDisplayManager.preferredDisplayCriteria = displayCriteria;
        }
        else
        {
          // switch back to tvOS defined user settings if we get
          // zero or less than value for refreshRate. Should never happen :)
          avDisplayManager.preferredDisplayCriteria = nil;
        }
        std::string dynamicRangeString = "Unknown";
        switch (dynamicRange)
        {
          case 0 ... 1:
            dynamicRangeString = "SDR";
            break;
          case 2 ... 3:
            dynamicRangeString = "HDR10";
            break;
          case 4:
            dynamicRangeString = "DolbyVision";
            break;
        }
        CLog::Log(LOGDEBUG, "displayRateSwitch request: refreshRate = %.2f, dynamicRange = %s",
                  refreshRate, dynamicRangeString.c_str());
      }
    }
  }
}

//--------------------------------------------------------------
- (void)displayRateReset
{
  if (CServiceBroker::GetSettingsComponent()->GetSettings()->GetInt(
                                                                    CSettings::SETTING_VIDEOPLAYER_ADJUSTREFRESHRATE) != ADJUST_REFRESHRATE_OFF)
  {
    if (__builtin_available(tvOS 11.2, *))
    {
      if ([m_window respondsToSelector:@selector(avDisplayManager)])
      {
        // setting preferredDisplayCriteria to nil will
        // switch back to tvOS defined user settings
        auto avDisplayManager = [m_window avDisplayManager];
        avDisplayManager.preferredDisplayCriteria = nil;
      }
    }
  }
}

//--------------------------------------------------------------
- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context
{
  if ([keyPath isEqualToString:@"displayModeSwitchInProgress"])
  {
    // tracking displayModeSwitchInProgress via NSKeyValueObservingOptionNew,
    // any changes in displayModeSwitchInProgress will fire this callback.
    if (__builtin_available(tvOS 11.2, *))
    {
      std::string switchState = "NO";
      int dynamicRange = 0;
      float refreshRate = self.getDisplayRate;
      if ([m_window respondsToSelector:@selector(avDisplayManager)])
      {
        auto avDisplayManager = [m_window avDisplayManager];
        auto displayCriteria = avDisplayManager.preferredDisplayCriteria;
        // preferredDisplayCriteria can be nil, this is NOT an error
        // and just indicates tvOS defined user settings which we cannot see.
        if (displayCriteria != nil)
        {
          refreshRate = displayCriteria.refreshRate;
          dynamicRange = displayCriteria.videoDynamicRange;
        }
        if ([avDisplayManager isDisplayModeSwitchInProgress] == YES)
        {
          switchState = "YES";
          CWinSystemTVOS* winSystem = dynamic_cast<CWinSystemTVOS*>(CServiceBroker::GetWinSystem());
          winSystem->AnnounceOnLostDevice();
          winSystem->StartLostDeviceTimer();
        }
        else
        {
          switchState = "DONE";
          CWinSystemTVOS* winSystem = dynamic_cast<CWinSystemTVOS*>(CServiceBroker::GetWinSystem());
          winSystem->StopLostDeviceTimer();
          winSystem->AnnounceOnResetDevice();
          // displayLinkTick is tracking actual refresh duration.
          // when isDisplayModeSwitchInProgress == NO, we have switched
          // and stablized. We might have switched to some other
          // rate than what we requested. setting preferredDisplayCriteria is
          // only a request. For example, 30Hz might only be avaliable in HDR
          // and asking for 30Hz/SDR might result in 60Hz/SDR and
          // g_graphicsContext.SetFPS needs the actual refresh rate.
          refreshRate = self.getDisplayRate;
        }
      }
      //! @todo
      //g_graphicsContext.SetFPS(refreshRate);
      std::string dynamicRangeString = "Unknown";
      switch (dynamicRange)
      {
        case 0 ... 1:
          dynamicRangeString = "SDR";
          break;
        case 2 ... 3:
          dynamicRangeString = "HDR10";
          break;
        case 4:
          dynamicRangeString = "DolbyVision";
          break;
      }
      CLog::Log(LOGDEBUG,
                "displayModeSwitchInProgress == %s, refreshRate = %.2f, dynamicRange = %s",
                +switchState.c_str(), refreshRate, dynamicRangeString.c_str());
    }
  }
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - gesture creators/recognizers
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)createSiriSwipeGestureRecognizers
{
  // these are for tracking tap/pan/swipe state only,
  // tvOS focus engine will handle the navigation.
  UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(SiriSwipeHandler:)];
  swipeLeft.delaysTouchesBegan = NO;
  swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
  swipeLeft.delegate = self;
  [self.focusView  addGestureRecognizer:swipeLeft];
  
  //single finger swipe right
  UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(SiriSwipeHandler:)];
  swipeRight.delaysTouchesBegan = NO;
  swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
  swipeRight.delegate = self;
  [self.focusView  addGestureRecognizer:swipeRight];
  
  //single finger swipe up
  UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(SiriSwipeHandler:)];
  swipeUp.delaysTouchesBegan = NO;
  swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
  swipeUp.delegate = self;
  [self.focusView  addGestureRecognizer:swipeUp];
  
  //single finger swipe down
  UISwipeGestureRecognizer *swipeDown = [[UISwipeGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(SiriSwipeHandler:)];
  swipeDown.delaysTouchesBegan = NO;
  swipeDown.direction = UISwipeGestureRecognizerDirectionDown;
  swipeDown.delegate = self;
  [self.focusView  addGestureRecognizer:swipeDown];
}

//--------------------------------------------------------------
- (void)createSiriPanGestureRecognizers
{
  // these are for tracking tap/pan/swipe state only,
  // tvOS focus engine will handle the navigation.
  self.panRecognizer = [[UIPanGestureRecognizer alloc]
                        initWithTarget:self action:@selector(SiriPanHandler:)];
  self.panRecognizer.delegate = self;
  [self.focusView addGestureRecognizer:self.panRecognizer];
}

//--------------------------------------------------------------
- (void)createSiriTapGestureRecognizers
{
  auto singletap = [[UITapGestureRecognizer alloc]
                    initWithTarget:self action:@selector(SiriSingleTapHandler:)];
  singletap.numberOfTapsRequired = 1;
  // The default press type is select, when this property is set to an empty array,
  // the gesture recognizer will respond to taps like a touch pad like surface
  singletap.allowedPressTypes = @[];
  singletap.allowedTouchTypes = @[@(UITouchTypeIndirect)];
  singletap.delegate = self;
  [self.focusView addGestureRecognizer:singletap];
  
  self.doubleTapRecognizer = [[UITapGestureRecognizer alloc]
                              initWithTarget:self action:@selector(SiriDoubleTapHandler:)];
  self.doubleTapRecognizer.numberOfTapsRequired = 2;
  self.doubleTapRecognizer.allowedPressTypes = @[];
  self.doubleTapRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirect)];
  [self.focusView addGestureRecognizer:self.doubleTapRecognizer];
  
  self.tripleTapRecognizer = [[UITapGestureRecognizer alloc]
                              initWithTarget:self action:@selector(SiriTripleTapHandler:)];
  self.tripleTapRecognizer.numberOfTapsRequired = 3;
  self.tripleTapRecognizer.allowedPressTypes = @[];
  self.tripleTapRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirect)];
  self.tripleTapRecognizer.delegate = self;
  [self.focusView addGestureRecognizer:self.tripleTapRecognizer];
  
  [singletap requireGestureRecognizerToFail:self.doubleTapRecognizer];
  [self.doubleTapRecognizer requireGestureRecognizerToFail:self.tripleTapRecognizer];
}

//--------------------------------------------------------------
- (void)createSiriPressGesturecognizers
{
  // we always have these under tvos,
  // both ir and siri remotes respond to these
  auto menuRecognizer = [[UITapGestureRecognizer alloc]
                         initWithTarget: self action: @selector(SiriMenuHandler:)];
  menuRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeMenu]];
  menuRecognizer.delegate  = self;
  [self.focusView addGestureRecognizer: menuRecognizer];
  
  auto longSelectRecognizer = [[UILongPressGestureRecognizer alloc]
                               initWithTarget: self action: @selector(SiriLongSelectHandler:)];
  longSelectRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeSelect]];
  longSelectRecognizer.minimumPressDuration = 0.001;
  longSelectRecognizer.delegate = self;
  [self.focusView addGestureRecognizer: longSelectRecognizer];
  
  auto selectRecognizer = [[UITapGestureRecognizer alloc]
                           initWithTarget: self action: @selector(SiriLongSelectHandler:)];
  selectRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypeSelect]];
  selectRecognizer.delegate  = self;
  [selectRecognizer requireGestureRecognizerToFail:longSelectRecognizer];
  [self.focusView addGestureRecognizer: selectRecognizer];
  
  auto playPauseRecognizer = [[UITapGestureRecognizer alloc]
                              initWithTarget: self action: @selector(SiriPlayPauseHandler:)];
  playPauseRecognizer.allowedPressTypes = @[[NSNumber numberWithInteger:UIPressTypePlayPause]];
  playPauseRecognizer.delegate  = self;
  [self.focusView addGestureRecognizer: playPauseRecognizer];
  
  // ir remote presses only, left/right/up/down
  auto upRecognizer = [[UILongPressGestureRecognizer alloc]
                       initWithTarget: self action: @selector(IRRemoteUpArrowPressed:)];
  upRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeUpArrow]];
  upRecognizer.minimumPressDuration = 0.001;
  upRecognizer.delegate = self;
  [self.focusView addGestureRecognizer: upRecognizer];
  
  auto downRecognizer = [[UILongPressGestureRecognizer alloc]
                         initWithTarget: self action: @selector(IRRemoteDownArrowPressed:)];
  downRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeDownArrow]];
  downRecognizer.minimumPressDuration = 0.001;
  downRecognizer.delegate = self;
  [self.focusView addGestureRecognizer: downRecognizer];
  
  auto leftRecognizer = [[UILongPressGestureRecognizer alloc]
                         initWithTarget: self action: @selector(IRRemoteLeftArrowPressed:)];
  leftRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeLeftArrow]];
  leftRecognizer.minimumPressDuration = 0.001;
  leftRecognizer.delegate = self;
  [self.focusView addGestureRecognizer: leftRecognizer];
  
  auto rightRecognizer = [[UILongPressGestureRecognizer alloc]
                          initWithTarget: self action: @selector(IRRemoteRightArrowPressed:)];
  rightRecognizer.allowedPressTypes  = @[[NSNumber numberWithInteger:UIPressTypeRightArrow]];
  rightRecognizer.minimumPressDuration = 0.001;
  rightRecognizer.delegate = self;
  [self.focusView addGestureRecognizer: rightRecognizer];
}

//--------------------------------------------------------------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
  if ([gestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
    return YES;
  }
  if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
    return YES;
  }
  if ([gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
    return YES;
  }
  return NO;
}

//--------------------------------------------------------------
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
  if ([gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]] && [otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]])
  {
    return YES;
  }
  return NO;
}

//--------------------------------------------------------------
// GestureRecognizers are used to manage the focus action type state machine.
// There are three types, tap, pan and swipe. For taps, these
// can be menu, select, play/pause buttons or up/down/right/left taps
// on trackpad, or up/down/right/left on IR remote. One could call
// them presses but it's easier to just deal with them all as taps.
// (ie directional taps on trackpad are similar to directional presses on ir remotes)
// The tvOS focus engine will call shouldUpdateFocusInContext/didUpdateFocusInContext
// but we need to know which focus action type so we can do the right thing.
#if logfocus
static const char* focusActionTypeNames[] = {
  "none",
  "tap",
  "pan",
  "swipe",
};
#endif
typedef enum FocusActionTypes
{
  FocusActionTap  = 1,
  FocusActionPan  = 2,
  FocusActionSwipe = 3,
} FocusActionTypes;
// default action is FocusActionTap, gestureRecognizers will
// set the correct type before shouldUpdateFocusInContext is hit
int focusActionType = FocusActionTap;

int swipeCounter = 0;
bool swipeOrPanNoMore = false;
CGRect swipeStartingParentViewRect;
FocusLayerView *swipeStartingParent;
ORIENTATION swipeStartingFocusedOrientation;

//--------------------------------------------------------------
// called before touchesBegan:withEvent: is called on the gesture recognizer
// for a new touch. return NO to prevent the gesture recognizer from seeing this touch
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
  // disable osdsettings auto close timer.
  [self.m_osdSettingsAutoHideTimer invalidate];
  
  // Block the recognition of tap gestures from other views
  if ( [touch.view isKindOfClass:[KeyboardView class]] )
    return NO;
  
  // same for FocusLayerViewPlayerProgress
  if ( [touch.view isKindOfClass:[FocusLayerViewPlayerProgress class]] )
    return NO;
  
  // only had double/triple tap recognizers enabled
  // during fulscreen video playback, or they slow down tap navigation
  if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo() &&
      !m_enableRemoteExpertMode &&
      !g_application.CurrentFileItem().IsPVR())
  {
    if (!self.doubleTapRecognizer.enabled)
      self.doubleTapRecognizer.enabled = YES;
    if (!self.tripleTapRecognizer.enabled)
      self.tripleTapRecognizer.enabled = YES;
    // disable pan recognizer so we can
    // seek/ff/rw while keep a finger on touchpad
    if (self.self.panRecognizer.enabled)
      self.self.panRecognizer.enabled = NO;
  }
  else
  {
    if (self.doubleTapRecognizer.enabled)
      self.doubleTapRecognizer.enabled = NO;
    if (self.tripleTapRecognizer.enabled)
      self.tripleTapRecognizer.enabled = NO;
    // enable pan recognizer for navigation
    if (!self.self.panRecognizer.enabled)
      self.self.panRecognizer.enabled = YES;
  }
  
  // important, this gestureRecognizer gets called before any other tap/pas/swipe handler
  // including shouldUpdateFocusInContext/didUpdateFocusInContext. So we can
  // setup the initial focusActionType to tap.
  //CLog::Log(LOGDEBUG, "shouldReceiveTouch:FocusActionTap, %ld", (long)gestureRecognizer.state);
  focusActionType = FocusActionTap;
  return YES;
}

//--------------------------------------------------------------
// called before pressesBegan:withEvent: is called on the gesture recognizer
// for a new press. return NO to prevent the gesture recognizer from seeing this press
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceivePress:(UIPress *)press
{
  // disable osdsettings auto close timer.
  [self.m_osdSettingsAutoHideTimer invalidate];
  
  // Block the recognition of press gestures from other views
  if ( [press.responder isKindOfClass:[KeyboardView class]] )
    return NO;
  // same for FocusLayerViewPlayerProgress
  if ( [press.responder isKindOfClass:[FocusLayerViewPlayerProgress class]] )
  {
    switch (press.type)
    {
        // we handle those here
      case UIPressTypeMenu:
      case UIPressTypeSelect:
      case UIPressTypePlayPause:
        break;
      default:
        return NO;
    }
  }
  
  BOOL handled = YES;
  // important, this gestureRecognizer gets called before any other press handler
  // including shouldUpdateFocusInContext/didUpdateFocusInContext. So we can
  // setup the initial focusActionType to tap.
  //CLog::Log(LOGDEBUG, "shouldReceivePress:FocusActionTap, %ld", (long)gestureRecognizer.state);
  focusActionType = FocusActionTap;
  switch (press.type)
  {
      // single press key, but also detect hold and back to tvos.
    case UIPressTypeMenu:
    {
      // menu is special.
      //  a) if at our home view, should return to atv home screen
      //  b) if not, let it pass to us
      int focusedWindowID = CFocusEngineHandler::GetInstance().GetFocusWindowID();
      
      // Alert!!! hack below to allow script.plex to go directly to Apple Home
      bool exitToAppleTV = false;
      /*
      if (focusedWindowID >= 13000 && focusedWindowID <= 13100)
      {
        CGUIWindow *pWindow = (CGUIWindow*)CServiceBroker::GetGUI()->GetWindowManager().GetWindow(focusedWindowID);
        if (!pWindow)
          return NULL;
        const std::string &homeWindow = "script-plex-home.xml";
        std::string xmlfile = pWindow->GetProperty("xmlfile").asString();
        if (xmlfile.find(homeWindow) != std::string::npos)
        {
          AddonPtr addon;
          const std::string &addonID = "script.plex";
          CAddonMgr::GetInstance().GetAddon(addonID, addon, ADDON_SCRIPT, false);
          if (addon && !addon->GetSetting("allow_exit").empty())
          {
            exitToAppleTV = (addon->GetSetting("allow_exit") == "false");
          }
        }
      }
       */
      // End of hack!!
      if (focusedWindowID == WINDOW_HOME || exitToAppleTV)
      {
        CLog::Log(LOGDEBUG, "shouldReceivePress:focusedWindowID == WINDOW_HOME");
        handled = NO;
      }
      break;
    }
      
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

//--------------------------------------------------------------
//--------------------------------------------------------------
// The whole purpose of this function is to break a single
// select click into left, right and center clicks.
// This is the only way to detect the location of click.
// It could also be used to detect if a use has a finger
// resting on the track pad.
CGRect selectUpBounds    = { 0.4f,  0.0f, 1.2f, 0.4f};
CGRect selectDownBounds  = { 0.4f,  1.6f, 1.2f, 0.4f};
CGRect selectLeftBounds  = { 0.0f,  0.0f, 0.4f, 2.0f};
CGRect selectRightBounds = { 1.6f,  0.0f, 0.4f, 2.0f};
CGPoint touchAbsPosition;

//--------------------------------------------------------------
- (void)initGameController
{
  //FIXME: fixme
  /*
  [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                    object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note)
   {
     // Capturing 'self' strongly in this block is likely to lead to a retain cycle
     // so creating a weak reference to self for access inside the block
     __weak XBMCController *weakSelf = self;
     
     self.gcController = note.object;
     self.gcController.microGamepad.reportsAbsoluteDpadValues = YES;
     self.gcController.microGamepad.valueChangedHandler = ^(GCMicroGamepad *gamepad, GCControllerElement *element)
     {
       // dpad axis values ranges from -1.0 to 1.0
       // where -1, -1 is bottom, left on trackpad.
       // referenced from center (0, 0) of touchpad.
       CGPoint startPoint = CGPointMake(
                                        gamepad.dpad.xAxis.value, gamepad.dpad.yAxis.value);
       touchAbsPosition = startPoint;
       // translate to (0,0) in top, left, (2,2) bottom, right
       // do this so we can use CGRectContainsPoint and bounding rects
       startPoint.x += 1.0;
       startPoint.y  = 1.0 - startPoint.y;
       
       weakSelf.m_touchPosition = TOUCH_CENTER;
       if (CGRectContainsPoint(selectUpBounds, startPoint))
         weakSelf.m_touchPosition = TOUCH_UP;
       else if (CGRectContainsPoint(selectDownBounds, startPoint))
         weakSelf.m_touchPosition = TOUCH_DOWN;
       else if (CGRectContainsPoint(selectLeftBounds, startPoint))
         weakSelf.m_touchPosition = TOUCH_LEFT;
       else if (CGRectContainsPoint(selectRightBounds, startPoint))
         weakSelf.m_touchPosition = TOUCH_RIGHT;
#if 0
       NSLog(@"microGamepad: A(%d), U(%d), D(%d), L(%d), R(%d), point %@",
             gamepad.buttonA.pressed,
             gamepad.dpad.up.pressed,
             gamepad.dpad.down.pressed,
             gamepad.dpad.left.pressed,
             gamepad.dpad.right.pressed,
             NSStringFromCGPoint(startPoint));
       switch(weakSelf.m_touchPosition)
       {
         case TOUCH_UP:
           NSLog(@"microGamepad: TOUCH_UP");
           break;
         case TOUCH_DOWN:
           NSLog(@"microGamepad: TOUCH_DOWN");
           break;
         case TOUCH_LEFT:
           NSLog(@"microGamepad: TOUCH_LEFT");
           break;
         case TOUCH_RIGHT:
           NSLog(@"microGamepad: TOUCH_RIGHT");
           break;
         case TOUCH_CENTER:
           NSLog(@"microGamepad: TOUCH_CENTER");
           break;
       }
#endif
     };
   }];
   */
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - bluetooth keyboard support methods
//--------------------------------------------------------------
//--------------------------------------------------------------

//TODO: To backport from MrMC


//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - internal key press methods
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)sendButtonPressed:(int)buttonId
{
  int actionID;
  std::string actionName;

  // Translate using custom controller translator.
  if (CServiceBroker::GetInputManager().TranslateCustomControllerString(
          CServiceBroker::GetGUI()->GetWindowManager().GetActiveWindowOrDialog(), "SiriRemote",
          buttonId, actionID, actionName))
  {
    // break screensaver
    g_application.ResetSystemIdleTimer();
    g_application.ResetScreenSaver();

    // in case we wokeup the screensaver or screen - eat that action...
    if (g_application.WakeUpScreenSaverAndDPMS())
      return;
    CServiceBroker::GetInputManager().QueueAction(CAction(actionID, 1.0f, 0.0f, actionName));
  }
  else
  {
    CLog::Log(LOGDEBUG, "ERROR mapping customcontroller action. CustomController: %s %i",
              "SiriRemote", buttonId);
  }
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - touch/gesture handlers
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)OSDSettingsAutoHideHandler
{
  /*
  if (CFocusEngineHandler::GetInstance().GetFocusWindowID() == WINDOW_DIALOG_OSD_SETTINGS)
  {
    // if OSD Settings window is in focus, dismiss it
    // the msg is really a toggle.
    KODI::MESSAGING::CApplicationMessenger::GetInstance().PostMsg(
                                                                  TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_SHOW_OSD_SETTINGS)));
  }
  [self.m_osdSettingsAutoHideTimer invalidate];
   */
}
//--------------------------------------------------------------
- (IBAction)SiriSwipeHandler:(UISwipeGestureRecognizer *)sender
{
  // these are for tracking tap/pan/swipe state only,
  // tvOS focus engine will handle the navigation.
  if (m_appAlive == YES)
  {
    switch (sender.state)
    {
      case UIGestureRecognizerStateRecognized:
      {
        swipeCounter = 0;
        swipeOrPanNoMore = false;
        focusActionType = FocusActionSwipe;
#if logfocus
        CLog::Log(LOGDEBUG, "SiriSwipeHandler:StateRecognized:FocusActionSwipe");
#endif
        //FIXME: FIXME
        /*
        if ([self hasPlayerProgressScrubbing])
        {
          // if hasPlayerProgressScrubbing, then shouldUpdateFocusInContext will
          // early return with NO. Handle showing OSD Settings here.
          if (sender.direction == UISwipeGestureRecognizerDirectionDown)
          {
            // show OSD Settings on down swipe, up swipe to hide will get handled naturally
            // via shouldUpdateFocusInContext/didUpdateFocusInContext routines
            KODI::MESSAGING::CApplicationMessenger::GetInstance().PostMsg(
                                                                          TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_SHOW_OSD_SETTINGS)));
            // auto close OSD Settings after 10 seconds if no focus change.
            self.m_osdSettingsAutoHideTimer = [NSTimer scheduledTimerWithTimeInterval:10
                                                                               target:self selector:@selector(OSDSettingsAutoHideHandler) userInfo:nil repeats:YES];
          }
        }
         */
        swipeStartingParent = [self findParentView:_focusLayer.infocus.view];
        swipeStartingParentViewRect = swipeStartingParent.bounds;
        swipeStartingFocusedOrientation = [self getFocusedOrientation];
#if logfocus
        CLog::Log(LOGDEBUG, "SiriSwipeHandler:StateRecognized:ParentViewRect %f, %f, %f, %f",
                  swipeStartingParentViewRect.origin.x,
                  swipeStartingParentViewRect.origin.y,
                  swipeStartingParentViewRect.origin.x + swipeStartingParentViewRect.size.width,
                  swipeStartingParentViewRect.origin.y + swipeStartingParentViewRect.size.height);
#endif
      }
        break;
      default:
#if logfocus
        CLog::Log(LOGDEBUG, "SiriSwipeHandler:StateRecognized:other %ld", sender.state);
#endif
        break;
    }
  }
}
static CGPoint panTouchAbsStart;
//--------------------------------------------------------------
- (IBAction)SiriPanHandler:(UIPanGestureRecognizer *)sender
{
  // these are for tracking tap/pan/swipe state only,
  // tvOS focus engine will handle the navigation.
  if (m_appAlive == YES)
  {
    switch (sender.state)
    {
      case UIGestureRecognizerStateBegan:
      {
        swipeCounter = 0;
        swipeOrPanNoMore = false;
        focusActionType = FocusActionPan;
#if logfocus
        CLog::Log(LOGDEBUG, "SiriPanHandler:StateBegan:FocusActionPan");
#endif
        FocusLayerView *parentView = [self findParentView:_focusLayer.infocus.view];
        swipeStartingParentViewRect = parentView.bounds;
        swipeStartingParentViewRect = parentView.bounds;
#if logfocus
        CLog::Log(LOGDEBUG, "SiriPanHandler:StateBegan: %f, %f, %f, %f",
                  swipeStartingParentViewRect.origin.x,
                  swipeStartingParentViewRect.origin.y,
                  swipeStartingParentViewRect.origin.x + swipeStartingParentViewRect.size.width,
                  swipeStartingParentViewRect.origin.y + swipeStartingParentViewRect.size.height);
#endif
        
        panTouchAbsStart = touchAbsPosition;
        CFocusEngineHandler::GetInstance().ClearAnimation();
#if logfocus
        CLog::Log(LOGDEBUG, "SiriPanHandler:UIGestureRecognizerStateBegan");
#endif
      }
        break;
      case UIGestureRecognizerStateChanged:
      {
        if (!CFocusEngineHandler::GetInstance().IsWindowPVR())
        {
          FocusEngineAnimate focusAnimate = FocusEngineAnimate();
          float dx = touchAbsPosition.x - panTouchAbsStart.x;
          float dy = touchAbsPosition.y - panTouchAbsStart.y;
          focusAnimate.slideX = dx;
          focusAnimate.slideY = dy;
          CFocusEngineHandler::GetInstance().UpdateAnimation(focusAnimate);
#if logfocus
          CLog::Log(LOGDEBUG, "SiriPanHandler:UIGestureRecognizerStateChanged");
#endif
        }
      }
        break;
      default:
        CFocusEngineHandler::GetInstance().ClearAnimation();
#if logfocus
        CLog::Log(LOGDEBUG, "SiriPanHandler:StateRecognized:other %ld", sender.state);
#endif
        break;
    }
  }
}
//--------------------------------------------------------------
- (void)SiriSingleTapHandler:(UITapGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    switch (sender.state)
    {
      case UIGestureRecognizerStateEnded:
      {
        if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo() &&
            !g_application.GetAppPlayer().IsPaused())
        {
#if logfocus
          CLog::Log(LOGDEBUG, "SiriSingleTapHandler:StateEnded");
#endif
          /*
           //FIXME: FIXME
          //show (2.5sec auto hide)/hide normal progress bar
          if (g_graphicsContext.GetDisplayAfterSeek())
            g_graphicsContext.SetDisplayAfterSeek(0);
          else
            g_graphicsContext.SetDisplayAfterSeek(2500);
           */
        }
      }
        break;
      default:
        break;
    }
  }
}
//--------------------------------------------------------------
- (void)SiriDoubleTapHandler:(UITapGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    switch (sender.state)
    {
      case UIGestureRecognizerStateEnded:
#if logfocus
        CLog::Log(LOGDEBUG, "SiriDoubleTapHandler:StateEnded");
#endif
        // placeholder to alter progress bar time display
        break;
      default:
        break;
    }
  }
}
//--------------------------------------------------------------
- (void)SiriTripleTapHandler:(UITapGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    switch (sender.state)
    {
      case UIGestureRecognizerStateEnded:
      {
        if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo() && !g_application.GetAppPlayer().IsPaused())
        {
#if logfocus
          CLog::Log(LOGDEBUG, "SiriTripleTapHandler:StateEnded");
#endif
          KODI::MESSAGING::CApplicationMessenger::GetInstance().PostMsg(
                                                                        TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_SHOW_SUBTITLES)));
        }
      }
        break;
      default:
        break;
    }
  }
}
//--------------------------------------------------------------
- (void)SiriMenuHandler:(UITapGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateEnded:
    {
#if logfocus
      CLog::Log(LOGDEBUG, "SiriMenuHandler:StateEnded");
#endif
      if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
      {
        if ([self hasPlayerProgressScrubbing] && g_application.GetAppPlayer().IsPaused())
        {
          // video playback, we are paused and progress bar scrubber is up
          [self sendButtonPressed:SiriRemote_PausePlayClick];
        }
        else
        {
          // normal video playback
          if (m_stopPlaybackOnMenu)
            CApplicationMessenger::GetInstance().PostMsg(TMSG_MEDIA_STOP);
          else
            [self sendButtonPressed:SiriRemote_MenuClickAtHome];
        }
      }
      else
      {
        [self sendButtonPressed:SiriRemote_MenuClick];
      }
      break;
    }
    default:
      break;
  }
}
//--------------------------------------------------------------
- (void)SiriPlayPauseHandler:(UITapGestureRecognizer *) sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateEnded:
#if logfocus
      CLog::Log(LOGDEBUG, "SiriPlayPauseHandler:StateEnded");
#endif
      [self sendButtonPressed:SiriRemote_PausePlayClick];
      break;
    default:
      break;
  }
}
//--------------------------------------------------------------
typedef enum
{
  SELECT_NAVIGATION = 0,
  SELECT_SLIDESHOW,
  SELECT_VIDEOPLAY,
  SELECT_VIDEOPAUSED,
} SELECT_STATE;
SELECT_STATE selectState = SELECT_NAVIGATION;
TOUCH_POSITION touchPositionAtStateBegan = TOUCH_CENTER;
//--------------------------------------------------------------
- (void)SiriLongSelectHoldHandler
{
  self.m_selectHoldCounter++;
  if (selectState == SELECT_VIDEOPLAY && !g_application.CurrentFileItem().IsLiveTV())
  {
    if (self.m_selectHoldCounter == 1)
    {
      switch(touchPositionAtStateBegan)
      {
        case TOUCH_LEFT:
          // use 8X speed rewind.
          [self sendButtonPressed:SiriRemote_IR_Rewind];
          [self sendButtonPressed:SiriRemote_IR_Rewind];
          [self sendButtonPressed:SiriRemote_IR_Rewind];
          break;
        case TOUCH_RIGHT:
          // use 8X speed forward.
          [self sendButtonPressed:SiriRemote_IR_FastForward];
          [self sendButtonPressed:SiriRemote_IR_FastForward];
          [self sendButtonPressed:SiriRemote_IR_FastForward];
          break;
        default:
          break;
      }
    }
  }
  else
  {
    [self.m_selectHoldTimer invalidate];
    [self sendButtonPressed:SiriRemote_CenterHold];
  }
}
//--------------------------------------------------------------
- (void)SiriLongSelectHandler:(UITapGestureRecognizer *)sender
{
  switch (sender.state)
  {
    case UIGestureRecognizerStateBegan:
    {
#if logfocus
      CLog::Log(LOGDEBUG, "SiriLongSelectHandler:StateBegan");
#endif
      self.m_selectHoldCounter = 0;
      // assume we are navigating
      selectState = SELECT_NAVIGATION;
      if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
      {
        selectState = SELECT_VIDEOPLAY;
        if (g_application.GetAppPlayer().IsPaused())
          selectState = SELECT_VIDEOPAUSED;
      }
      else if (CFocusEngineHandler::GetInstance().GetFocusWindowID() == WINDOW_SLIDESHOW)
      {
        selectState = SELECT_SLIDESHOW;
      }
      touchPositionAtStateBegan = m_touchPosition;
      self.m_selectHoldTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(SiriLongSelectHoldHandler) userInfo:nil repeats:YES];
    }
      break;
    case UIGestureRecognizerStateChanged:
#if logfocus
      CLog::Log(LOGDEBUG, "SiriLongSelectHandler:StateChanged");
#endif
      if (selectState == SELECT_NAVIGATION)
      {
        if (self.m_selectHoldCounter > 1)
        {
          [self.m_selectHoldTimer invalidate];
          [self sendButtonPressed:SiriRemote_CenterHold];
        }
      }
      break;
    case UIGestureRecognizerStateEnded:
#if logfocus
      CLog::Log(LOGDEBUG, "SiriLongSelectHandler:StateEnded");
#endif
      [self.m_selectHoldTimer invalidate];
      if (self.m_selectHoldCounter < 1)
      {
        // hold timer never fired,
        // this is a normal press/release cycle
        switch(selectState)
        {
          case SELECT_NAVIGATION:
            // user was nav'ing around in skin and clicked
            [self sendButtonPressed:SiriRemote_CenterClick];
            break;
          case SELECT_SLIDESHOW:
            // do nothing
            break;
          case SELECT_VIDEOPLAY:
            // fullscreen video was playing but not paused
            switch(touchPositionAtStateBegan)
          {
            case TOUCH_UP:
            {
              int chapterCount = g_application.GetAppPlayer().GetChapterCount();
              if (chapterCount > 0 || ![self hasPlayerProgressScrubbing])
              {
                // chapter seek or channel change for pvr
                [self sendButtonPressed:SiriRemote_UpTap];
              }
            }
              break;
            case TOUCH_DOWN:
            {
              int chapterCount = g_application.GetAppPlayer().GetChapterCount();
              if (chapterCount > 0 || ![self hasPlayerProgressScrubbing])
              {
                // chapter seek or channel change for pvr
                [self sendButtonPressed:SiriRemote_DownTap];
              }
            }
              break;
            case TOUCH_LEFT:
              // seek backward
              [self sendButtonPressed:SiriRemote_LeftTap];
              break;
            case TOUCH_RIGHT:
              // seek forward
              [self sendButtonPressed:SiriRemote_RightTap];
              break;
            case TOUCH_CENTER:
              // pause playback
              if ([self hasPlayerProgressScrubbing])
                [self sendButtonPressed:SiriRemote_PausePlayClick];
              else
                [self sendButtonPressed:SiriRemote_CenterClick];
              break;
          }
            break;
          case SELECT_VIDEOPAUSED:
            // idea here is that if user does not use ExpertMode, it shoud behave like "Netflix" in fullscreen
            // would have been easier to do this in keymap, but we could not make it backward compatible
            if ([_focusLayer.infocus.view isKindOfClass:[FocusLayerViewPlayerProgress class]] )
            {
              // progress bar with scrubber was up
              double appTotalTime = g_application.GetTotalTime();
              double appPercentage = g_application.GetPercentage();
              double appSeekTime = appPercentage * appTotalTime / 100;
              FocusLayerViewPlayerProgress *viewPlayerProgress = (FocusLayerViewPlayerProgress*)_focusLayer.infocus.view;
              double percentage = [viewPlayerProgress getSeekTimePercentage];
              double seekTime = percentage * appTotalTime / 100;
              // only seek if change is more than 500ms
              if (fabs(appSeekTime - seekTime) > 0.5)
              {
                //FIXME: fixme
                /*
                g_application.SeekPercentage(percentage, true);
                // turn off display after seek.
                g_infoManager.SetDisplayAfterSeek(0);
                 */
              }
              else
              {
                // resume playback
                [self sendButtonPressed:SiriRemote_PausePlayClick];
              }
            }
            else
            {
              // if we are not in progress bar,
              // then some other window/dialog is in front
              // so we are just like navigating around
              [self sendButtonPressed:SiriRemote_CenterClick];
            }
            break;
        }
      }
      else
      {
        // hold timer fired,
        // this is a press/hold/release cycle
        switch(selectState)
        {
          case SELECT_NAVIGATION:
            // hold timer handled button press, do nothing
            break;
          case SELECT_SLIDESHOW:
            // hold timer handled button press, do nothing
            break;
          case SELECT_VIDEOPLAY:
            // hold timer put us into ff/rw
            // restore to normal playback speed.
            if (g_application.GetAppPlayer().IsPlaying() && !g_application.GetAppPlayer().IsPaused())
            {
              CApplicationMessenger::GetInstance().PostMsg(
                                                           TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
            }
          case SELECT_VIDEOPAUSED:
            // do nothing
            break;
        }
      }
      selectState = SELECT_NAVIGATION;
      break;
    case UIGestureRecognizerStateCancelled:
#if logfocus
      CLog::Log(LOGDEBUG, "SiriLongSelectHandler:StateCancelled");
#endif
      [self.m_selectHoldTimer invalidate];
      selectState = SELECT_NAVIGATION;
      break;
    default:
      break;
  }
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - IR remote directional handlers
//--------------------------------------------------------------
//--------------------------------------------------------------

// only used during video playback, tvOS focus engine will
// automatically include IR directional events during navigation.
//--------------------------------------------------------------
- (void)IRLeftArrowArrowHoldHandler
{
  self.m_irArrowHoldCounter++;
  [self.m_irArrowHoldTimer invalidate];
  // use 8X speed rewind.
  [self sendButtonPressed:SiriRemote_IR_Rewind];
  [self sendButtonPressed:SiriRemote_IR_Rewind];
  [self sendButtonPressed:SiriRemote_IR_Rewind];
}

//--------------------------------------------------------------
- (IBAction)IRRemoteLeftArrowPressed:(UIGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
    {
      switch (sender.state)
      {
        case UIGestureRecognizerStateBegan:
#if logfocus
          CLog::Log(LOGDEBUG, "IRRemoteLeftArrowPressed:StateBegan");
#endif
          self.m_irArrowHoldCounter = 0;
          self.m_irArrowHoldTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                                     target:self selector:@selector(IRLeftArrowArrowHoldHandler) userInfo:nil repeats:YES];
          break;
        case UIGestureRecognizerStateEnded:
#if logfocus
          CLog::Log(LOGDEBUG, "IRRemoteLeftArrowPressed:StateEnded");
#endif
          [self.m_irArrowHoldTimer invalidate];
          if (self.m_irArrowHoldCounter < 1)
          {
            // we need to check if we have [self hasPlayerProgressScrubbing], only send the tap if true
            if ([self hasPlayerProgressScrubbing])
              [self sendButtonPressed:SiriRemote_LeftTap];
          }
          else
          {
            // hold timer put us into ff/rw
            // restore to normal playback speed.
            if (g_application.GetAppPlayer().IsPlaying() && !g_application.GetAppPlayer().IsPaused())
            {
              CApplicationMessenger::GetInstance().PostMsg(
                                                           TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
            }
          }
        case UIGestureRecognizerStateCancelled:
          [self.m_irArrowHoldTimer invalidate];
          break;
        default:
          break;
      }
    }
  }
}

//--------------------------------------------------------------
- (void)IRRightArrowArrowHoldHandler
{
  self.m_irArrowHoldCounter++;
  [self.m_irArrowHoldTimer invalidate];
  // use 8X speed fastforeward.
  [self sendButtonPressed:SiriRemote_IR_FastForward];
  [self sendButtonPressed:SiriRemote_IR_FastForward];
  [self sendButtonPressed:SiriRemote_IR_FastForward];
}

//--------------------------------------------------------------
- (IBAction)IRRemoteRightArrowPressed:(UIGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
    {
      switch (sender.state)
      {
        case UIGestureRecognizerStateBegan:
#if logfocus
          CLog::Log(LOGDEBUG, "IRRemoteRightArrowPressed:StateBegan");
#endif
          self.m_irArrowHoldCounter = 0;
          self.m_irArrowHoldTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                                     target:self selector:@selector(IRRightArrowArrowHoldHandler) userInfo:nil repeats:YES];
          break;
        case UIGestureRecognizerStateEnded:
#if logfocus
          CLog::Log(LOGDEBUG, "IRRemoteRightArrowPressed:StateEnded");
#endif
          [self.m_irArrowHoldTimer invalidate];
          if (self.m_irArrowHoldCounter < 1)
          {
            // we need to check if we have [self hasPlayerProgressScrubbing], only send the tap if true
            if ([self hasPlayerProgressScrubbing])
              [self sendButtonPressed:SiriRemote_RightTap];
          }
          else
          {
            // hold timer put us into ff/rw
            // restore to normal playback speed.
            if (g_application.GetAppPlayer().IsPlaying() && !g_application.GetAppPlayer().IsPaused())
            {
              CApplicationMessenger::GetInstance().PostMsg(
                                                           TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
            }
          }
          break;
        case UIGestureRecognizerStateCancelled:
          [self.m_irArrowHoldTimer invalidate];
          break;
        default:
          break;
      }
    }
  }
}

//--------------------------------------------------------------
// start repeating after 0.25s
#define REPEATED_KEYPRESS_DELAY_S 0.25
// pause 0.05s (50ms) between keypresses
#define REPEATED_KEYPRESS_PAUSE_S 0.15
static CFAbsoluteTime keyPressTimerStartSeconds;

//--------------------------------------------------------------
- (void)startKeyPressTimer:(int)keyId
{
  [self startKeyPressTimer:keyId doBeforeDelay:true withDelay:REPEATED_KEYPRESS_DELAY_S];
}

//--------------------------------------------------------------
- (void)startKeyPressTimer:(int)keyId doBeforeDelay:(bool)doBeforeDelay withDelay:(NSTimeInterval)delay
{
  [self startKeyPressTimer:keyId doBeforeDelay:doBeforeDelay withDelay:delay withInterval:REPEATED_KEYPRESS_PAUSE_S];
}

//--------------------------------------------------------------
- (void)startKeyPressTimer:(int)keyId doBeforeDelay:(bool)doBeforeDelay withDelay:(NSTimeInterval)delay withInterval:(NSTimeInterval)interval
{
  if (self.pressAutoRepeatTimer != nil)
    [self stopKeyPressTimer];
  
  if (doBeforeDelay)
    [self sendButtonPressed:keyId];
  
  NSNumber *number = [NSNumber numberWithInt:keyId];
  NSDate *fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
  
  keyPressTimerStartSeconds = CFAbsoluteTimeGetCurrent() + delay;
  // schedule repeated timer which starts after REPEATED_KEYPRESS_DELAY_S
  // and fires every REPEATED_KEYPRESS_PAUSE_S
  NSTimer *timer = [[NSTimer alloc] initWithFireDate:fireDate
                                            interval:interval target:self selector:@selector(keyPressTimerCallback:) userInfo:number repeats:YES];
  
  // schedule the timer to the runloop
  [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
  self.pressAutoRepeatTimer = timer;
}

//--------------------------------------------------------------
- (void)stopKeyPressTimer
{
  if (self.pressAutoRepeatTimer != nil)
  {
    [self.pressAutoRepeatTimer invalidate];
    self.pressAutoRepeatTimer = nil;
  }
}

//--------------------------------------------------------------
- (void)keyPressTimerCallback:(NSTimer*)theTimer
{
  NSNumber *keyId = [theTimer userInfo];
  [self sendButtonPressed:[keyId intValue]];
}

//--------------------------------------------------------------
- (IBAction)IRRemoteUpArrowPressed:(UIGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
    {
      switch (sender.state)
      {
        case UIGestureRecognizerStateBegan:
#if logfocus
          CLog::Log(LOGDEBUG, "PlayerProgress::IRRemoteUpArrowPressed");
#endif
          if (g_application.GetAppPlayer().IsPaused())
            [self startKeyPressTimer:SiriRemote_UpTap doBeforeDelay:true withDelay:REPEATED_KEYPRESS_DELAY_S];
          else
            [self sendButtonPressed:SiriRemote_UpTap];
          break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateChanged:
        case UIGestureRecognizerStateCancelled:
          [self stopKeyPressTimer];
          break;
        default:
          break;
      }
    }
  }
}

//--------------------------------------------------------------
- (IBAction)IRRemoteDownArrowPressed:(UIGestureRecognizer *)sender
{
  if (m_appAlive == YES)
  {
    if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
    {
      switch (sender.state)
      {
        case UIGestureRecognizerStateBegan:
#if logfocus
          CLog::Log(LOGDEBUG, "PlayerProgress::IRRemoteDownArrowPressed");
#endif
          if (g_application.GetAppPlayer().IsPaused())
            [self startKeyPressTimer:SiriRemote_DownTap doBeforeDelay:true withDelay:REPEATED_KEYPRESS_DELAY_S];
          else
            [self sendButtonPressed:SiriRemote_DownTap];
          break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateChanged:
        case UIGestureRecognizerStateCancelled:
          [self stopKeyPressTimer];
          break;
        default:
          break;
      }
    }
  }
}

//--------------------------------------------------------------
- (void)remoteControlReceivedWithEvent:(UIEvent*)receivedEvent
{
#if logfocus
  CLog::Log(LOGDEBUG, "remoteControlReceivedWithEvent");
#endif
  if (receivedEvent.type == UIEventTypeRemoteControl)
  {
    switch (receivedEvent.subtype)
    {
      case UIEventSubtypeRemoteControlPlay:
      case UIEventSubtypeRemoteControlPause:
      case UIEventSubtypeRemoteControlTogglePlayPause:
        // check if not in background, we can get this if sleep is forced
        if (m_controllerState < MC_BACKGROUND)
          CApplicationMessenger::GetInstance().PostMsg(
                                                       TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAYPAUSE)));
        break;
      case UIEventSubtypeRemoteControlStop:
        [self sendButtonPressed:SiriRemote_IR_Stop];
        break;
      case UIEventSubtypeRemoteControlNextTrack:
        [self sendButtonPressed:SiriRemote_IR_NextTrack];
        break;
      case UIEventSubtypeRemoteControlPreviousTrack:
        [self sendButtonPressed:SiriRemote_IR_PreviousTrack];
        break;
      case UIEventSubtypeRemoteControlBeginSeekingForward:
        // use 4X speed forward.
        [self sendButtonPressed:SiriRemote_IR_FastForward];
        [self sendButtonPressed:SiriRemote_IR_FastForward];
        break;
      case UIEventSubtypeRemoteControlBeginSeekingBackward:
        // use 4X speed rewind.
        [self sendButtonPressed:SiriRemote_IR_Rewind];
        [self sendButtonPressed:SiriRemote_IR_Rewind];
        break;
      case UIEventSubtypeRemoteControlEndSeekingForward:
      case UIEventSubtypeRemoteControlEndSeekingBackward:
        // restore to normal playback speed.
        if (g_application.GetAppPlayer().IsPlaying() && !g_application.GetAppPlayer().IsPaused())
        {
          CApplicationMessenger::GetInstance().PostMsg(
                                                       TMSG_GUI_ACTION, WINDOW_INVALID, -1, static_cast<void*>(new CAction(ACTION_PLAYER_PLAY)));
        }
        break;
      default:
        LOG(@"unhandled subtype: %d", (int)receivedEvent.subtype);
        break;
    }
  }
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - focus changed idle timer
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)startFocusTimer
{
  m_focusIdleState = false;
  
  //PRINT_SIGNATURE();
  if (self.focusIdleTimer != nil)
    [self stopFocusTimer];
  
  NSDate *fireDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
  NSTimer *timer = [[NSTimer alloc] initWithFireDate:fireDate
                                            interval:0.0
                                              target:self
                                            selector:@selector(setFocusIdleState)
                                            userInfo:nil
                                             repeats:NO];
  
  [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
  self.focusIdleTimer = timer;
}

//--------------------------------------------------------------
- (void)stopFocusTimer
{
  //PRINT_SIGNATURE();
  if (self.focusIdleTimer != nil)
  {
    [self.focusIdleTimer invalidate];
    self.focusIdleTimer = nil;
  }
  m_focusIdleState = false;
}

//--------------------------------------------------------------
- (void)setFocusIdleState
{
  //PRINT_SIGNATURE();
  m_focusIdleState = true;
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - remote/siri focus engine routines
//--------------------------------------------------------------
//--------------------------------------------------------------

- (UIFocusSoundIdentifier)soundIdentifierForFocusUpdateInContext:(UIFocusUpdateContext *)context
{
  // disable focus engine sound effect when playing video
  // it will mess up audio if doing passthrough.
  if ( g_application.GetAppPlayer().IsPlayingVideo() )
  {
    if (@available(tvOS 11.0, *))
      return UIFocusSoundIdentifierNone;
    else
      return nil;
  }
  if (@available(tvOS 11.0, *))
  {
    //FIXME: fixme
    /*
    if (CSettings::GetInstance().GetString(CSettings::SETTING_LOOKANDFEEL_SOUNDSKIN) == "resource.uisounds.tvos")
      return UIFocusSoundIdentifierDefault;
    else
     */
      return UIFocusSoundIdentifierNone;
  }
  else
    return nil;
}

//--------------------------------------------------------------
-(ORIENTATION)getFocusedOrientation
{
  return CFocusEngineHandler::GetInstance().GetFocusOrientation();
}

//--------------------------------------------------------------
CGRect debugView1;
CGRect debugView2;
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments
{
  // The order of the items in the preferredFocusEnvironments array is the
  // priority that the focus engine will use when picking the focused item
  
  // if native keyboard is up, we don't want to send any button presses to MrMC
  if (m_nativeKeyboardActive)
    return [super preferredFocusEnvironments];
  
  [self updateFocusLayerInFocus];
  FocusLayerView *parentView = [self findParentView:_focusLayer.infocus.view];
  if (parentView && _focusLayer.infocus.view)
  {
    CGRect parentViewRect = parentView.bounds;
    if (!CGRectEqualToRect(debugView1, parentViewRect))
    {
      debugView1 = parentViewRect;
      /*
       CLog::Log(LOGDEBUG, "preferredFocusEnvironments: parentViewRect %f, %f, %f, %f",
       parentViewRect.origin.x,  parentViewRect.origin.y,
       parentViewRect.origin.x + parentViewRect.size.width,
       parentViewRect.origin.y + parentViewRect.size.height);
       */
    }
    CGRect focusLayerViewRect = _focusLayer.infocus.view.bounds;
    if (!CGRectEqualToRect(debugView2, focusLayerViewRect))
    {
      debugView2 = focusLayerViewRect;
      /*
       CLog::Log(LOGDEBUG, "preferredFocusEnvironments: focusLayerViewRect %f, %f, %f, %f",
       focusLayerViewRect.origin.x,  focusLayerViewRect.origin.y,
       focusLayerViewRect.origin.x + focusLayerViewRect.size.width,
       focusLayerViewRect.origin.y + focusLayerViewRect.size.height);
       */
    }
    
    NSMutableArray *viewArray = [NSMutableArray array];
    [viewArray addObject:(UIView*)_focusLayer.infocus.view];
    for (size_t indx = 0; indx < _focusLayer.infocus.items.size(); ++indx)
    {
      if (_focusLayer.infocus.core != _focusLayer.infocus.items[indx].core)
        [viewArray addObject:(UIView*)_focusLayer.infocus.items[indx].view];
    }
    [viewArray addObject:(UIView*)self.focusViewTop];
    [viewArray addObject:(UIView*)self.focusViewLeft];
    [viewArray addObject:(UIView*)self.focusViewRight];
    [viewArray addObject:(UIView*)self.focusViewBottom];
    //[viewArray addObject:(UIView*)parentView];
    return viewArray;
  }
  else if (_focusLayer.infocus.view)
  {
#if logfocus
    CGRect focusLayerViewRect = _focusLayer.infocus.view.bounds;
    if (!CGRectEqualToRect(debugView2, focusLayerViewRect))
    {
      debugView2 = focusLayerViewRect;
      CLog::Log(LOGDEBUG, "preferredFocusEnvironments: focusLayerViewRect %f, %f, %f, %f",
                focusLayerViewRect.origin.x,  focusLayerViewRect.origin.y,
                focusLayerViewRect.origin.x + focusLayerViewRect.size.width,
                focusLayerViewRect.origin.y + focusLayerViewRect.size.height);
    }
#endif
    // need a focusable view or risk bouncing out on menu presses
    if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo() ||
        CFocusEngineHandler::GetInstance().GetFocusWindowID() == WINDOW_SLIDESHOW)
    {
      if ( [_focusLayer.infocus.view canBecomeFocused] == NO )
        [self.focusView setFocusable:true];
    }
    return @[(UIView*)_focusLayer.infocus.view];
  }
  else
  {
#if logfocus
    CLog::Log(LOGDEBUG, "preferredFocusEnvironments");
#endif
    // need a focusable view or risk bouncing out on menu presses
    if ( [self.focusView canBecomeFocused] == NO )
      [self.focusView setFocusable:true];
    return @[(UIView*)self.focusView];
  }
}

//--------------------------------------------------------------
- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context
       withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator
{
  // reset PanTouchAbsStart when jumping to next item
  // so the next item's animation starts centered.
  if (focusActionType == FocusActionPan ||
      focusActionType == FocusActionSwipe)
  {
    switch (context.focusHeading)
    {
      case UIFocusHeadingUp:
      case UIFocusHeadingDown:
      case UIFocusHeadingLeft:
      case UIFocusHeadingRight:
#if logfocus
        CLog::Log(LOGDEBUG, "didUpdateFocusInContext:panTouchAbsStart reset");
#endif
        panTouchAbsStart = touchAbsPosition;
        break;
    }
  }
  
  // if we had a focus change, send the heading down to core
  switch (context.focusHeading)
  {
    case UIFocusHeadingUp:
      if (focusActionType == FocusActionSwipe)
        [self sendButtonPressed:SiriRemote_UpSwipe];
      else
        [self sendButtonPressed:SiriRemote_UpTap];
      if (context.nextFocusedItem == self.focusViewTop)
        [self setNeedsFocusUpdate];
#if logfocus
      CLog::Log(LOGDEBUG, "didUpdateFocusInContext:UIFocusHeadingUp");
#endif
      break;
    case UIFocusHeadingDown:
      if (focusActionType == FocusActionSwipe)
        [self sendButtonPressed:SiriRemote_DownSwipe];
      else
        [self sendButtonPressed:SiriRemote_DownTap];
      if (context.nextFocusedItem == self.focusViewBottom)
        [self setNeedsFocusUpdate];
#if logfocus
      CLog::Log(LOGDEBUG, "didUpdateFocusInContext:UIFocusHeadingDown");
#endif
      break;
    case UIFocusHeadingLeft:
      if (focusActionType == FocusActionSwipe)
        [self sendButtonPressed:SiriRemote_LeftSwipe];
      else
        [self sendButtonPressed:SiriRemote_LeftTap];
      if (context.nextFocusedItem == self.focusViewLeft)
        [self setNeedsFocusUpdate];
#if logfocus
      CLog::Log(LOGDEBUG, "didUpdateFocusInContext:UIFocusHeadingLeft");
#endif
      break;
    case UIFocusHeadingRight:
      if (focusActionType == FocusActionSwipe)
        [self sendButtonPressed:SiriRemote_RightSwipe];
      else
        [self sendButtonPressed:SiriRemote_RightTap];
      if (context.nextFocusedItem == self.focusViewRight)
        [self setNeedsFocusUpdate];
#if logfocus
      CLog::Log(LOGDEBUG, "didUpdateFocusInContext:UIFocusHeadingRight");
#endif
      break;
    case UIFocusHeadingNone:
    case UIFocusHeadingNext:
    case UIFocusHeadingPrevious:
      break;
  }
}

//--------------------------------------------------------------
- (BOOL)shouldUpdateFocusInContext:(UIFocusUpdateContext *)context
{
  // Asks whether the system should allow a focus update to occur.
  
  // slow down nav, we respond much faster than normal tvOS apps
  usleep(50 * 1000);
  
  // useful debugging help
  // po [UIFocusDebugger help]
  // po [UIFocusDebugger status]
  // po [UIFocusDebugger simulateFocusUpdateRequestFromEnvironment:self]
  // po [UIFocusDebugger checkFocusabilityForItem:(UIView *)0x155e2a040]
  // quicklook on passed context.
  
  // Once we get hit from control view, we might also get one regarding the parent view
  // The one exception to this possible recursion is if you return NO. This stops the recursion.
  // We can use this to handle slide out panels that are represented by hidden views
  // Above/Below/Right/Left (self.focusViewTop and friends) which are subviews the main focus View.
  // So detect the focus request, post direction message to core and cancel tvOS focus update.
#if logfocus
  std::string focusedOrientation = "UNDEFINED";
  switch([self getFocusedOrientation])
  {
    case VERTICAL:
      focusedOrientation = "VERTICAL";
      break;
    case HORIZONTAL:
      focusedOrientation = "HORIZONTAL";
      break;
    default:
      break;
  }
  
  CLog::Log(LOGDEBUG, "shouldUpdateFocusInContext: count(%d), %s, type %s",
            swipeCounter, focusedOrientation.c_str(), focusActionTypeNames[focusActionType]);
#endif
  // do not allow focus changes when playing video
  // we handle those directly. Otherwise taps/swipes will cause wild seeks.
  if ([self hasPlayerProgressScrubbing])
  {
    swipeOrPanNoMore = true;
    return NO;
  }
  
  // previouslyFocusedItem may be nil if no item was focused.
#if logfocus
  CLog::Log(LOGDEBUG, "shouldUpdateFocusInContext: previous %p, next %p",
            context.previouslyFocusedItem, context.nextFocusedItem);
#endif
  if (focusActionType == FocusActionPan || focusActionType == FocusActionSwipe)
  {
    swipeCounter++;
    if (context.focusHeading != UIFocusHeadingNone)
    {
      //FIXME: fixme
      /*
      if (CSettings::GetInstance().GetBool(CSettings::SETTING_LOOKANDFEEL_NAVIGATIONWRAPPING))
      {
        // track focus idle time, if focus was idled,
        // allow wrapping in lists, else no wrapping in lists
        CServiceBroker::GetGUI()->GetWindowManager().SetWrapOverride(!m_focusIdleState);
      }
      else
      {
        // disable wrapping
        CServiceBroker::GetGUI()->GetWindowManager().SetWrapOverride(true);
      }
       */
      [self startFocusTimer];
    }
    
    // swipes are the problem child :)
    if (swipeOrPanNoMore)
      return NO;
    
    if (swipeStartingFocusedOrientation != [self getFocusedOrientation])
      swipeOrPanNoMore = true;
    
    CGRect nextFocusedItemRect = ((FocusLayerView*)context.nextFocusedItem).bounds;
#if logfocus
    CGRect previousItemRect = ((FocusLayerView*)context.previouslyFocusedItem).bounds;
    CLog::Log(LOGDEBUG, "shouldUpdateFocusInContext: previousItemRect %f, %f, %f, %f",
              previousItemRect.origin.x, previousItemRect.origin.y,
              previousItemRect.origin.x + previousItemRect.size.width,
              previousItemRect.origin.y + previousItemRect.size.height);
    
    CLog::Log(LOGDEBUG, "shouldUpdateFocusInContext: nextFocusedItemRect %f, %f, %f, %f",
              nextFocusedItemRect.origin.x, nextFocusedItemRect.origin.y,
              nextFocusedItemRect.origin.x + nextFocusedItemRect.size.width,
              nextFocusedItemRect.origin.y + nextFocusedItemRect.size.height);
#endif
    
    if (!CGRectContainsRect(swipeStartingParentViewRect, nextFocusedItemRect))
    {
      if (context.nextFocusedItem == self.focusViewTop ||
          context.nextFocusedItem == self.focusViewLeft ||
          context.nextFocusedItem == self.focusViewRight ||
          context.nextFocusedItem == self.focusViewBottom )
      {
#if logfocus
        CLog::Log(LOGDEBUG, "shouldUpdateFocusInContext: Hit in borderView");
#endif
      }
      else
      {
        FocusLayerView *nextFocusedItemParentView = [self findParentView:(FocusLayerView*)context.nextFocusedItem];
        if (swipeStartingParent == nullptr ||
            nextFocusedItemParentView == nullptr ||
            swipeStartingParent->core != nextFocusedItemParentView->core)
        {
          swipeOrPanNoMore = true;
#if logfocus
          CLog::Log(LOGDEBUG, "shouldUpdateFocusInContext: Not in same parent view");
#endif
        }
      }
      [self setNeedsFocusUpdate];
    }
  }
  
  return YES;
}

//--------------------------------------------------------------
- (FocusLayerView*)findParentView:(FocusLayerView *)thisView
{
  if (!thisView)
    return nullptr;
  
  FocusLayerView *parentView = nullptr;
  for (auto viewIt = _focusLayer.views.begin(); viewIt != _focusLayer.views.end(); ++viewIt)
  {
    auto &views = *viewIt;
    for (size_t bndx = 0; bndx < views.items.size(); ++bndx)
    {
      if (thisView->core == views.items[bndx].core)
      {
        parentView = views.view;
        break;
      }
    }
  }
  return parentView;
}

//--------------------------------------------------------------
- (void)clearSubViews
{
  @autoreleasepool {
    NSArray *subviews = self.focusView.subviews;
    if (subviews && [subviews count])
    {
      for (UIView *view in subviews)
      {
        if (view == self.focusViewLeft)
          continue;
        if (view == self.focusViewRight)
          continue;
        if (view == self.focusViewTop)
          continue;
        if (view == self.focusViewBottom)
          continue;
        [view removeFromSuperview];
      }
    }
  }
}

//--------------------------------------------------------------
- (void)debugSubViews
{
  NSArray *subviews = self.focusView.subviews;
  if (subviews && [subviews count])
  {
    for (UIView *view in subviews)
    {
      LOG(@"debugSubViews: %@", view);
    }
  }
}

//--------------------------------------------------------------
- (void) initFocusLayerViews:(std::vector<FocusLayerControl>&)focusViews
               withCoreViews:(std::vector<FocusEngineCoreViews>&)coreViews
{
  // build through our views in reverse order (so that last (window) is first)
  for (auto viewIt = coreViews.rbegin(); viewIt != coreViews.rend(); ++viewIt)
  {
    auto &viewItem = *viewIt;
    // m_glView.bounds does not have screen scaling
    CGRect rect = CGRectMake(
                             viewItem.rect.x1/m_screenScale, viewItem.rect.y1/m_screenScale,
                             viewItem.rect.Width()/m_screenScale, viewItem.rect.Height()/m_screenScale);
    
    FocusLayerControl focusView;
    focusView.rect = rect;
    focusView.type = viewItem.type;
    focusView.core = viewItem.control;
    focusView.view = nil;
    for (auto itemsIt = viewItem.items.begin(); itemsIt != viewItem.items.end(); ++itemsIt)
    {
      auto &item = *itemsIt;
      // m_glView.bounds does not have screen scaling
      CGRect rect = CGRectMake(
                               item.rect.x1/m_screenScale, item.rect.y1/m_screenScale,
                               item.rect.Width()/m_screenScale, item.rect.Height()/m_screenScale);
      
      FocusLayerItem focusItem;
      focusItem.rect = rect;
      focusItem.type = item.type;
      focusItem.core = item.control;
      focusItem.view = nil;
      focusView.items.push_back(focusItem);
    }
    focusViews.push_back(focusView);
  }
}

//--------------------------------------------------------------
- (void) loadFocusLayerViews:(std::vector<FocusLayerControl>&)focusViews
{
  // build up new focusLayer from core items.
  [self clearSubViews];
  
#if dumpviewsonload
  if (!focusViews.empty())
    CLog::Log(LOGDEBUG, "updateFocusLayer: begin");
#endif
  
  bool hasPlayerProgressScrubbing = [self hasPlayerProgressScrubbing] && g_application.GetAppPlayer().IsPaused();
  int viewCount = 0;
  for (auto viewsIt = focusViews.begin(); viewsIt != focusViews.end(); ++viewsIt)
  {
    auto &view = *viewsIt;
    
    if (view.type == "window")
    {
      CGUIControl *guiControl = (CGUIControl*)view.core;
      if (guiControl)
      {
        int windowID = guiControl->GetID();
        switch(windowID)
        {
            // helps with fast swipe nav on some skins
          case WINDOW_HOME:
          case WINDOW_MUSIC_NAV:
          case WINDOW_VIDEO_NAV:
          //case WINDOW_MUSIC_FILES:
          //case WINDOW_VIDEO_FILES:
          //case WINDOW_MEDIA_SOURCES:
            // need to skip making UIView if it is fullscreen video
            // prevents possible running out of memory playing 4k video.
          case WINDOW_FULLSCREEN_VIDEO:
            continue;
        }
      }
    }
    
    if (view.type == "dialog")
    {
      //FIXME : fixme
      /*
      CGUIDialog *guiDialog = (CGUIDialog*)view.core;
      if (guiDialog)
      {
        int windowID = guiDialog->GetID();
        if (windowID != WINDOW_DIALOG_SLIDER)
        {
          if (!guiDialog->IsModalDialog())
            continue;
        }
      }
       */
    }
    
    FocusLayerView *focusLayerView = nil;
    focusLayerView = [[FocusLayerView alloc] initWithFrame:view.rect];
    [focusLayerView setFocusable:false];
    if (view.type == "window" || view.type == "dialog")
    {
      [focusLayerView setFocusable:true];
      [focusLayerView setViewVisible:false];
    }
    focusLayerView->core = view.core;
    view.view = focusLayerView;
    [self.focusView addSubview:focusLayerView];
#if dumpviewsonload
    CLog::Log(LOGDEBUG, "updateFocusLayer: %d, %s, %f, %f, %f, %f",
              viewCount, view.type.c_str(),
              view.rect.origin.x, view.rect.origin.y,
              view.rect.origin.x + view.rect.size.width, view.rect.origin.y + view.rect.size.height);
#endif
    for (auto itemsIt = view.items.begin(); itemsIt != view.items.end(); ++itemsIt)
    {
      auto &item = *itemsIt;
      FocusLayerView *focusLayerItem = nil;
      if (hasPlayerProgressScrubbing && item.type == "progress")
        focusLayerItem = [[FocusLayerViewPlayerProgress alloc] initWithFrame:item.rect];
      else
        focusLayerItem = [[FocusLayerView alloc] initWithFrame:item.rect];
      [focusLayerItem setFocusable:true];
      focusLayerItem->core = item.core;
      item.view = focusLayerItem;
      [self.focusView addSubview:focusLayerItem];
#if dumpviewsonload
      CLog::Log(LOGDEBUG, "updateFocusLayer: %d, %s, %f, %f, %f, %f",
                viewCount, item.type.c_str(),
                item.rect.origin.x, item.rect.origin.y,
                item.rect.origin.x + item.rect.size.width, item.rect.origin.y + item.rect.size.height);
#endif
    }
    viewCount++;
  }
  _focusLayer.views = focusViews;
  [self updateFocusLayerInFocus];
}

//--------------------------------------------------------------
- (bool) updateFocusLayerInFocus
{
  FocusLayerControl oldItem = _focusLayer.infocus;
  FocusLayerControl preferredItem;
  // default to focusView and in focus control
  preferredItem.view = self.focusView;
  preferredItem.core = CFocusEngineHandler::GetInstance().GetFocusControl();
  if (preferredItem.core)
  {
    if (CFocusEngineHandler::GetInstance().IsWindowFullScreenVideo())
    {
      if (CServiceBroker::GetGUI()->GetWindowManager().IsWindowVisible(WINDOW_DIALOG_SEEK_BAR))
      {
        for (size_t andx = 0; andx < _focusLayer.views.size(); ++andx)
        {
          for (size_t indx = 0; indx < _focusLayer.views[andx].items.size(); ++indx)
          {
            CGUIControl *guiControl = (CGUIControl*)_focusLayer.views[andx].items[indx].core;
            if (guiControl->GetControlType() == CGUIControl::GUICONTROL_PROGRESS)
            {
              preferredItem.type = _focusLayer.views[andx].items[indx].type;
              preferredItem.rect = _focusLayer.views[andx].items[indx].rect;
              preferredItem.view = _focusLayer.views[andx].items[indx].view;
              preferredItem.core = _focusLayer.views[andx].items[indx].core;
              _focusLayer.infocus = preferredItem;
              return (_focusLayer.infocus.view != oldItem.view);
            }
          }
        }
      }
    }
  }
  
  bool continueLooping = true;
  for (size_t andx = 0; andx < _focusLayer.views.size() && continueLooping; ++andx)
  {
    if (preferredItem.core == _focusLayer.views[andx].core)
    {
      preferredItem = _focusLayer.views[andx];
      break;
    }
    for (size_t bndx = 0; bndx < _focusLayer.views[andx].items.size(); ++bndx)
    {
      if (preferredItem.core == _focusLayer.views[andx].items[bndx].core)
      {
        preferredItem.type = _focusLayer.views[andx].items[bndx].type;
        preferredItem.rect = _focusLayer.views[andx].items[bndx].rect;
        preferredItem.view = _focusLayer.views[andx].items[bndx].view;
        // we don't really have to set core, but do it for completeness
        preferredItem.core = (CGUIControl*)_focusLayer.views[andx].items[bndx].core;
        preferredItem.items = _focusLayer.views[andx].items;
        continueLooping = false;
        break;
      }
    }
  }
  // setup the 'in focus' view
  _focusLayer.infocus = preferredItem;
  return (_focusLayer.infocus.view != oldItem.view);
}

//--------------------------------------------------------------
- (void) updateFocusLayerMainThread
{
  if (m_animating && !m_nativeKeyboardActive)
    [self performSelectorOnMainThread:@selector(updateFocusLayer) withObject:nil  waitUntilDone:NO];
}

//--------------------------------------------------------------
- (void) updateFocusLayer
{
  bool needUpdate = false;
  bool isBusy = CFocusEngineHandler::GetInstance().IsBusy();
  bool hideViews = CFocusEngineHandler::GetInstance().NeedToHideViews();
  std::vector<FocusEngineCoreViews> coreViews;
  CFocusEngineHandler::GetInstance().GetCoreViews(coreViews);
  if (isBusy || hideViews || coreViews.empty())
  {
    // if views are empty, we need a focusable focusView
    // or we unhook from the gestureRecognizer that traps
    // UIPressTypeMenu and we will bounce out to tvOS home.
    if (isBusy || coreViews.empty())
      [self.focusView setFocusable:true];
    _focusLayer.Reset();
    [self clearSubViews];
    [self updateFocusLayerInFocus];
    needUpdate = true;
  }
  else
  {
    // revert enable of focus for focusView (see above)
    // if we have built views, we need focusView set
    // to canBecomeFocused == NO
    if ( [self.focusView canBecomeFocused] == YES )
      [self.focusView setFocusable:false];
    // this is deep 'is equals' comparison
    // has to match in order and content.
    std::vector<FocusLayerControl> focusViews;
    [self initFocusLayerViews:focusViews withCoreViews:coreViews];
    if (FocusLayerViewsAreEqual(focusViews, _focusLayer.views))
    {
      needUpdate = [self updateFocusLayerInFocus];
    }
    else
    {
      [self loadFocusLayerViews:focusViews];
      needUpdate = true;
      //CLog::Log(LOGDEBUG, "updateFocusLayer:hideViews(%s), rebuild", hideViews ? "yes":"no");
    }
  }
  if (needUpdate)
  {
    [self.focusView setNeedsDisplay];
    // if the focus update is accepted by the focus engine,
    // focus is reset to the preferred focused view
    [self setNeedsFocusUpdate];
    // tells the focus engine to force a focus update immediately
    [self updateFocusIfNeeded];
  }
}

//--------------------------------------------------------------
//--------------------------------------------------------------
#pragma mark - Now Playing routines
//--------------------------------------------------------------
//--------------------------------------------------------------

- (void)setIOSNowPlayingInfo:(NSDictionary*)info
{
  self.m_nowPlayingInfo = info;
  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:self.m_nowPlayingInfo];
}

//--------------------------------------------------------------
- (void)onPlay:(NSDictionary*)item
{
  // @todo copy-paste from iOS
  NSMutableDictionary* dict = [[NSMutableDictionary alloc] init];
  
  NSString* title = [item objectForKey:@"title"];
  if (title && title.length > 0)
    [dict setObject:title forKey:MPMediaItemPropertyTitle];
  NSString* album = [item objectForKey:@"album"];
  if (album && album.length > 0)
    [dict setObject:album forKey:MPMediaItemPropertyAlbumTitle];
  NSArray* artists = [item objectForKey:@"artist"];
  if (artists && artists.count > 0)
    [dict setObject:[artists componentsJoinedByString:@" "] forKey:MPMediaItemPropertyArtist];
  NSNumber* track = [item objectForKey:@"track"];
  if (track)
    [dict setObject:track forKey:MPMediaItemPropertyAlbumTrackNumber];
  NSNumber* duration = [item objectForKey:@"duration"];
  if (duration)
    [dict setObject:duration forKey:MPMediaItemPropertyPlaybackDuration];
  NSArray* genres = [item objectForKey:@"genre"];
  if (genres && genres.count > 0)
    [dict setObject:[genres componentsJoinedByString:@" "] forKey:MPMediaItemPropertyGenre];
  
  if (NSClassFromString(@"MPNowPlayingInfoCenter"))
  {
    NSNumber* elapsed = [item objectForKey:@"elapsed"];
    if (elapsed)
      [dict setObject:elapsed forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber* speed = [item objectForKey:@"speed"];
    if (speed)
      [dict setObject:speed forKey:MPNowPlayingInfoPropertyPlaybackRate];
    NSNumber* current = [item objectForKey:@"current"];
    if (current)
      [dict setObject:current forKey:MPNowPlayingInfoPropertyPlaybackQueueIndex];
    NSNumber* total = [item objectForKey:@"total"];
    if (total)
      [dict setObject:total forKey:MPNowPlayingInfoPropertyPlaybackQueueCount];
  }
  /*
   other properities can be set:
   MPMediaItemPropertyAlbumTrackCount
   MPMediaItemPropertyComposer
   MPMediaItemPropertyDiscCount
   MPMediaItemPropertyDiscNumber
   MPMediaItemPropertyPersistentID
   
   Additional metadata properties:
   MPNowPlayingInfoPropertyChapterNumber;
   MPNowPlayingInfoPropertyChapterCount;
   */
  
  [self setIOSNowPlayingInfo:dict];
  
  m_playbackState = IOS_PLAYBACK_PLAYING;
}

//--------------------------------------------------------------
- (void)OnSpeedChanged:(NSDictionary*)item
{
  if (NSClassFromString(@"MPNowPlayingInfoCenter"))
  {
    NSMutableDictionary* info = [self.m_nowPlayingInfo mutableCopy];
    NSNumber* elapsed = [item objectForKey:@"elapsed"];
    if (elapsed)
      [info setObject:elapsed forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber* speed = [item objectForKey:@"speed"];
    if (speed)
      [info setObject:speed forKey:MPNowPlayingInfoPropertyPlaybackRate];
    
    [self setIOSNowPlayingInfo:info];
  }
}

//--------------------------------------------------------------
- (void)onPause:(NSDictionary*)item
{
  m_playbackState = IOS_PLAYBACK_PAUSED;
}

//--------------------------------------------------------------
- (void)onStop:(NSDictionary*)item
{
  [self setIOSNowPlayingInfo:nil];
  
  m_playbackState = IOS_PLAYBACK_STOPPED;
}






#pragma mark - private helper methods



@end
#undef BOOL

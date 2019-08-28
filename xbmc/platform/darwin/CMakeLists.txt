set(SOURCES DarwinUtils.mm
            DarwinNSUserDefaults.mm
            DictionaryUtils.mm
            FocusEngineHandler.cpp
            MemUtils.cpp
            PlatformDarwin.cpp)

set(HEADERS DarwinNSUserDefaults.h
            DarwinUtils.h
            DictionaryUtils.h
            FocusEngineHandler.h
            NSLogDebugHelpers.h
            PlatformDarwin.h)

core_add_library(platform_darwin)

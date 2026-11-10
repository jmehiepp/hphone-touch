ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
FINALPACKAGE = 1
include $(THEOS)/makefiles/common.mk
TOOL_NAME = hphone-touchd
hphone-touchd_FILES = daemon/main.m daemon/Bridge.m $(filter-out vendor/lua/src/lua.c vendor/lua/src/luac.c,$(wildcard vendor/lua/src/*.c))
hphone-touchd_CFLAGS = -Ivendor/lua/src -Idaemon -DLUA_USE_IOS -Wno-deprecated-declarations
hphone-touchd_OBJCFLAGS = -fobjc-arc
hphone-touchd_LDFLAGS = -lroothide -Wl,-sectcreate,__TEXT,__info_plist,daemon/Info.plist
hphone-touchd_FRAMEWORKS = Foundation UIKit CoreGraphics IOSurface Vision ImageIO IOKit
hphone-touchd_CODESIGN_FLAGS = -Sdaemon/entitlements.plist
hphone-touchd_INSTALL_PATH = /usr/bin
include $(THEOS_MAKE_PATH)/tool.mk
APPLICATION_NAME = HPhoneTouch
HPhoneTouch_FILES = app/main.m
HPhoneTouch_RESOURCE_FILES = app/Info.plist
HPhoneTouch_RESOURCE_DIRS = app/Resources
HPhoneTouch_FRAMEWORKS = UIKit WebKit Foundation
HPhoneTouch_CFLAGS = -fobjc-arc
HPhoneTouch_CODESIGN_FLAGS = -Sentitlements.plist
include $(THEOS_MAKE_PATH)/application.mk
after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/usr/share/hphone-touch
	cp -R web $(THEOS_STAGING_DIR)/usr/share/hphone-touch/
	mkdir -p $(THEOS_STAGING_DIR)/usr/share/hphone-touch/licenses
	cp vendor/lua/src/lua.h $(THEOS_STAGING_DIR)/usr/share/hphone-touch/licenses/Lua.txt
	cp LICENSE $(THEOS_STAGING_DIR)/usr/share/hphone-touch/licenses/HPhoneTouch.txt

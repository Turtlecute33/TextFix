# SPDX-License-Identifier: GPL-3.0-only
QT += core gui qml quick quickcontrols2 network dbus
CONFIG += c++17 release
CONFIG -= app_bundle
TARGET = textfix
TEMPLATE = app
isEmpty(TEXTFIX_VERSION): TEXTFIX_VERSION = 0.0.0
DEFINES += TEXTFIX_VERSION=\"\\\"$$TEXTFIX_VERSION\\\"\"
INCLUDEPATH += src
HEADERS += src/config.h src/aiclient.h src/desktop.h src/backend.h src/theme.h src/tray.h \
    src/pill.h src/pillscene.h src/layershell.h
SOURCES += src/main.cpp src/config.cpp src/aiclient.cpp src/desktop.cpp src/backend.cpp src/theme.cpp src/tray.cpp \
    src/pill.cpp src/pillscene.cpp
RESOURCES += src/resources.qrc
QMAKE_CXXFLAGS_RELEASE += -Os
linux {
    # The progress pill speaks the Wayland layer-shell protocol itself (see layershell.cpp).
    SOURCES += src/layershell.cpp
    DEFINES += TEXTFIX_LAYER_SHELL
    CONFIG += link_pkgconfig
    PKGCONFIG += wayland-client
    # qmake does not read the CXXFLAGS and LDFLAGS that makepkg and dpkg set, so the usual
    # hardening is given here: a PIE with full RELRO, stack protection and fortified libc calls.
    QMAKE_CXXFLAGS_RELEASE += -fPIE -fstack-protector-strong -fstack-clash-protection \
        -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections
    QMAKE_LFLAGS_RELEASE += -pie -Wl,-z,relro,-z,now -Wl,-z,noexecstack -Wl,--as-needed -Wl,--gc-sections
}

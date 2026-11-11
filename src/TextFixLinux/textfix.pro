# SPDX-License-Identifier: GPL-3.0-only
QT += core gui qml quick quickcontrols2 network dbus
CONFIG += c++17 release
CONFIG -= app_bundle
TARGET = textfix
TEMPLATE = app
isEmpty(TEXTFIX_VERSION): TEXTFIX_VERSION = 0.0.0
DEFINES += TEXTFIX_VERSION=\"\\\"$$TEXTFIX_VERSION\\\"\"
INCLUDEPATH += src
HEADERS += src/config.h src/aiclient.h src/desktop.h src/backend.h src/theme.h src/tray.h
SOURCES += src/main.cpp src/config.cpp src/aiclient.cpp src/desktop.cpp src/backend.cpp src/theme.cpp src/tray.cpp
RESOURCES += src/resources.qrc
QMAKE_CXXFLAGS_RELEASE += -Os
QMAKE_LFLAGS_RELEASE += -Wl,--as-needed

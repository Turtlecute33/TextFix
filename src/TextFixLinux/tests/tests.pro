QT += core gui qml quick quickcontrols2 network dbus testlib
CONFIG += c++17 testcase
TARGET = textfix_tests
TEMPLATE = app
INCLUDEPATH += ../src
HEADERS += ../src/config.h ../src/aiclient.h ../src/desktop.h ../src/backend.h ../src/theme.h ../src/pillscene.h
SOURCES += tests.cpp ../src/config.cpp ../src/aiclient.cpp ../src/desktop.cpp ../src/backend.cpp ../src/theme.cpp ../src/pillscene.cpp
RESOURCES += ../src/resources.qrc

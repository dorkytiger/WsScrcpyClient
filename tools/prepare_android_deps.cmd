@echo off
rem Offline/restricted-environment prerequisite for Android builds.
rem
rem Why this exists (measured 2026-10-08): `flutter build apk` fails without network at
rem
rem   Could not get resource '.../com/android/tools/build/gradle/8.5.0/gradle-8.5.0.pom'
rem     > Remote host terminated the handshake
rem   'kotlin-android' plugin requires one of the Android Gradle plugins.
rem     Please apply one of the following plugins to ':path_provider_android' project ...
rem
rem The cause is not this project: some plugins ship their own buildscript classpath
rem (path_provider_android-2.2.17/android/build.gradle pins AGP 8.5.0) and that classpath is
rem per-subproject, so it must resolve by itself. This machine's Gradle cache only has
rem 8.5.1 / 8.11.1 / 8.12.1 / 8.13.1 / 9.1.0 -> without network the build stops there.
rem
rem The PowerShell script aligns each plugin's pinned AGP version to the highest one that is
rem actually cached (idempotent; it only edits the machine-local pub cache, never this repo).
rem
rem NOTE: keep this file ASCII-only (cmd.exe parses .cmd with the OEM code page).
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare_android_deps.ps1" %*
exit /b %errorlevel%

@echo off
rem Short launcher. Keep this file in the same folder as claude-discord.ps1.
rem   cdiscord add
rem   cdiscord start
rem   cdiscord list
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-discord.ps1" %*

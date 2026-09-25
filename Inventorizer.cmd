@echo off
title XV's Windows PC Inventorizer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Inventorizer.ps1" %*

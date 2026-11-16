@echo off
chcp 65001 >nul
title 4 - 延时刷分（本地目标 30~50 分钟）
cd /d "%~dp0"
echo.
echo  ============================================
echo   按本地抓包开始时间，等待到随机 30~50 分钟后重放
echo   目标已过但未超过 50 分钟才直接重放
echo   超过上限、时间异常或缺少开始记录则报错中止
echo   服务端是否更新结束时间未经验证，不保证改变网页用时
echo   如果服务端只保留首次提交时间，延时重放不会改变它
echo   窗口别关，等待期间可以干别的
echo  ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Invoke-LabPerfect.ps1" -Apply -WaitRandomTime
echo.
pause

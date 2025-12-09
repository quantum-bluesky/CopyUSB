echo off
SET drv0=%1
SET drv1=%2
SET drv2=%3
SET drv3=%4
SET drv4=%5
SET drv5=%6
SET drv6=%7
SET drv7=%8
powershell -executionpolicy bypass -File .\removedrv.ps1 %drv0% %drv1% %drv2% %drv3% %drv4% %drv5% %drv6% %drv7%
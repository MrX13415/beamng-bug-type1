@echo off

cls
:: Go to parent folder for the folder of this file
pushd %~dp0..
echo %cd%

python build\py\bugtool.py

popd
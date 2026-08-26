@echo off

cls
:: Go to parent folder for the folder of this file
pushd %~dp0..

python Tools\py\app.py

popd
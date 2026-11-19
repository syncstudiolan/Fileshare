# Prepare Windows ONNX Runtime 1.28.x using Microsoft's official NuGet.
# Does NOT build, run, test or publish File Share.
param([string]$Version='1.28.0')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tmp=Join-Path ([IO.Path]::GetTempPath()) 'fileshare-native-onnx'
New-Item -ItemType Directory $tmp -Force | Out-Null
$pkg=Join-Path $tmp "onnx-$Version.nupkg"
$zip=Join-Path $tmp "onnx-$Version.zip"
$extract=Join-Path $tmp "nuget-$Version"
Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$Version/microsoft.ml.onnxruntime.$Version.nupkg" -OutFile $pkg
if((Get-Item $pkg).Length -lt 1048576){throw 'NuGet package unexpectedly small'}
Copy-Item $pkg $zip -Force
if(Test-Path $extract){Remove-Item $extract -Recurse -Force}
Expand-Archive $zip $extract -Force
$all=@(Get-ChildItem $extract -Recurse -File)
$header=$all | Where-Object {$_.Name -eq 'onnxruntime_cxx_api.h'} | Select-Object -First 1
$lib=$all | Where-Object {$_.Name -eq 'onnxruntime.lib' -and $_.FullName -match 'x64|amd64' -and $_.FullName -notmatch 'arm64|x86[/\\]'} | Select-Object -First 1
$dll=$all | Where-Object {$_.Name -eq 'onnxruntime.dll' -and $_.FullName -match 'x64|amd64' -and $_.FullName -notmatch 'arm64|x86[/\\]'} | Select-Object -First 1
if(-not $header -or -not $lib -or -not $dll){
  throw 'NuGet package does not include x64 ONNX C++ headers, import .lib and .dll'
}
$win=Join-Path $root 'windows'
$dest=Join-Path $win 'onnxruntime-sdk'
$include=Join-Path $dest 'include'
$binary=Join-Path $dest 'lib'
New-Item -ItemType Directory $include -Force | Out-Null
New-Item -ItemType Directory $binary -Force | Out-Null
Copy-Item (Join-Path $header.Directory.FullName '*.h') $include -Force
Copy-Item $lib.FullName (Join-Path $binary 'onnxruntime.lib') -Force
Get-ChildItem $dll.Directory.FullName -Filter '*.dll' -File | ForEach-Object {
  Copy-Item $_.FullName $binary -Force
}
foreach($file in @((Join-Path $include 'onnxruntime_cxx_api.h'),(Join-Path $binary 'onnxruntime.lib'),(Join-Path $binary 'onnxruntime.dll'))){
  if(-not (Test-Path $file) -or (Get-Item $file).Length -eq 0){throw "ONNX SDK incomplete: $file"}
}
Write-Host "Native ONNX DLL SHA256: $((Get-FileHash (Join-Path $binary 'onnxruntime.dll') -Algorithm SHA256).Hash)"
$cmake=Join-Path $win 'CMakeLists.txt'
if(-not (Test-Path $cmake)){throw 'Flutter generated Windows CMake is unavailable'}
$txt=Get-Content $cmake -Raw
$marker='include(flutter/generated_plugins.cmake)'
if(-not $txt.Contains($marker)){throw 'Unexpected Windows plugin registration layout'}
$patch=@'
set(USE_SYSTEM_ONNXRUNTIME ON CACHE BOOL "Use local Microsoft ONNX" FORCE)
set(ONNXRUNTIME_ROOT_DIR "CMK_SRC/onnxruntime-sdk" CACHE PATH "Native ONNX SDK" FORCE)
include(flutter/generated_plugins.cmake)
install(DIRECTORY "CMK_SRC/onnxruntime-sdk/lib/"
  DESTINATION "CMK_LIB" COMPONENT Runtime
  FILES_MATCHING PATTERN "*.dll")
'@
$patch=$patch.Replace('CMK_SRC','$'+'{CMAKE_SOURCE_DIR}').Replace('CMK_LIB','$'+'{INSTALL_BUNDLE_LIB_DIR}')
$txt=$txt.Replace($marker,$patch)
[IO.File]::WriteAllText($cmake,$txt,[Text.UTF8Encoding]::new($false))
Write-Host 'Prepared Microsoft ONNX SDK and CMake; did not run a build.'

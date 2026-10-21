$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$work = Join-Path $root 'work'
$dist = Join-Path $root 'dist'
$output = Join-Path $dist 'DropMePortable'
$licenses = Join-Path $output 'licenses'
New-Item -ItemType Directory -Path $work,$licenses -Force | Out-Null

function Download-Checked([string]$Url, [string]$File, [string]$ExpectedHash) {
    Invoke-WebRequest -Uri $Url -OutFile $File
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedHash.ToLowerInvariant()) { throw "Checksum mismatch for $Url" }
}

Expand-Archive -LiteralPath (Join-Path $root 'payload/components.zip') -DestinationPath (Join-Path $work 'components') -Force
$components = Join-Path $work 'components'
$nodeFile = Join-Path $work 'node.exe'
Download-Checked $manifest.nodeUrl $nodeFile $manifest.nodeSha256
$coreFile = Join-Path $output 'DropMe.core.exe'
Copy-Item -LiteralPath $nodeFile -Destination $coreFile

# Remove the original Node signature before embedding the already compiled app.
$bytes = [IO.File]::ReadAllBytes($coreFile)
$pe = [BitConverter]::ToInt32($bytes,0x3c)
$optional = $pe + 24
$magic = [BitConverter]::ToUInt16($bytes,$optional)
$directories = if ($magic -eq 0x20b) {112} else {96}
$security = $optional + $directories + 32
$certOffset = [BitConverter]::ToUInt32($bytes,$security)
$certSize = [BitConverter]::ToUInt32($bytes,$security+4)
[Array]::Clear($bytes,$security,8)
[Array]::Clear($bytes,$optional+64,4)
if ($certOffset -gt 0 -and ($certOffset+$certSize) -eq $bytes.Length) {
    $shortened = [byte[]]::new($certOffset)
    [Array]::Copy($bytes,$shortened,$certOffset)
    $bytes = $shortened
}
[IO.File]::WriteAllBytes($coreFile,$bytes)
& (Join-Path $components 'inject.exe') $coreFile (Join-Path $components 'dropme.blob')
if ($LASTEXITCODE -ne 0) { throw 'Embedding the compiled application failed.' }
$bytes = [IO.File]::ReadAllBytes($coreFile)
$encoding = [Text.Encoding]::GetEncoding(28591)
$binary = $encoding.GetString($bytes)
$fuse = 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2:0'
$index = $binary.IndexOf($fuse,[StringComparison]::Ordinal)
if ($index -lt 0) { throw 'Node SEA fuse missing.' }
$bytes[$index+$fuse.Length-1] = 49
[IO.File]::WriteAllBytes($coreFile,$bytes)
Copy-Item -LiteralPath (Join-Path $components 'DropMe.exe') -Destination (Join-Path $output 'DropMe.exe')
Copy-Item -LiteralPath (Join-Path $components 'README.txt') -Destination (Join-Path $output 'README.txt')
Copy-Item -LiteralPath (Join-Path $components 'NODE-LICENSE.txt') -Destination (Join-Path $licenses 'NODE-LICENSE.txt')

$ffmpegZip = Join-Path $work 'ffmpeg.zip'
Download-Checked $manifest.ffmpegUrl $ffmpegZip $manifest.ffmpegSha256
Expand-Archive -LiteralPath $ffmpegZip -DestinationPath (Join-Path $work 'ffmpeg') -Force
$ffmpeg = Get-ChildItem -LiteralPath (Join-Path $work 'ffmpeg') -Recurse -File -Filter ffmpeg.exe | Select-Object -First 1
if (-not $ffmpeg) { throw 'FFmpeg missing from download.' }
Copy-Item -LiteralPath $ffmpeg.FullName -Destination (Join-Path $output 'ffmpeg.exe')
$ffmpegRoot = Split-Path (Split-Path $ffmpeg.FullName -Parent) -Parent
$ffmpegLicense = Get-ChildItem -LiteralPath $ffmpegRoot -File | Where-Object Name -match '^LICENSE' | Select-Object -First 1
if (-not $ffmpegLicense) { throw 'FFmpeg license missing.' }
Copy-Item -LiteralPath $ffmpegLicense.FullName -Destination (Join-Path $licenses 'FFMPEG-LICENSE.txt')
$ffmpegExe = Join-Path $output 'ffmpeg.exe'
$version = & $ffmpegExe -version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg version unavailable.' }
$license = & $ffmpegExe -L 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg license unavailable.' }
$buildInfo = $version + "`n" + $license + "`nSource and build recipes: https://github.com/yt-dlp/FFmpeg-Builds`nFFmpeg source: https://github.com/FFmpeg/FFmpeg`n"
[IO.File]::WriteAllText((Join-Path $licenses 'FFMPEG-BUILD.txt'),$buildInfo)

$permitted = @('DropMe.exe','DropMe.core.exe','ffmpeg.exe','README.txt','licenses')
foreach ($item in Get-ChildItem -LiteralPath $output -Force) {
    if ($item.Name -notin $permitted) { throw "Unexpected distribution file: $($item.Name)" }
}
$zip = Join-Path $dist 'DropMePortable.zip'
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $dist 'DropMePortable.sha256.txt'),"$hash  DropMePortable.zip`n")
Write-Host "Packaged DropMe $($manifest.version)."

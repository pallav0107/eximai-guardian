Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path "$PSScriptRoot\.." ).Path
$distDir = Join-Path $root 'dist'
$stageDir = Join-Path $distDir 'stage'
$zipPath = Join-Path $distDir 'EximAI-Guardian.zip'

if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Copy-Item -Force (Join-Path $root 'guardian.ps1') $stageDir
New-Item -ItemType Directory -Force -Path (Join-Path $stageDir 'config') | Out-Null
Copy-Item -Force (Join-Path $root 'config\guardian.config.json') (Join-Path $stageDir 'config\guardian.config.json')
Copy-Item -Force (Join-Path $root 'README.md') $stageDir

if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath

Write-Host "Built: $zipPath"

# load-config.ps1 — 读取本机配置(config.local.json, gitignored),导出 $cfg 哈希表
# 用法:在调用方脚本顶部用"向上查找"定位本文件后再 dot-source
$ErrorActionPreference = 'Stop'
$configFile = Join-Path $PSScriptRoot 'config.local.json'
if (-not (Test-Path $configFile)) {
  Write-Error "config.local.json 缺失 ($configFile)。请复制 config.local.example.json 并填入本机路径后重试。"
  exit 1
}
$raw = Get-Content $configFile -Encoding UTF8 | ConvertFrom-Json

function ConvertTo-Hashtable($obj) {
  if ($null -eq $obj) { return $obj }
  if ($obj -is [System.Collections.Hashtable]) { return $obj }
  if ($obj -is [PSCustomObject]) {
    $ht = @{}
    foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = ConvertTo-Hashtable $p.Value }
    return $ht
  }
  return $obj
}
$cfg = ConvertTo-Hashtable $raw

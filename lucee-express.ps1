<#
.SYNOPSIS
  Assemble Lucee Express from Maven repositories (Maven Central by default) instead of downloading
  lucee-express-<version>.zip from cdn.lucee.org.

.EXAMPLE
  ./lucee-express.ps1 -Version 7.0.1.100 -Target C:\lucee\express
  ./lucee-express.ps1 7.0.1.100 ./express -Repos 'file:///C:/staging-repo','https://repo1.maven.org/maven2'

.NOTES
  PowerShell 5.1+ or 7+. Uses tar.exe (bsdtar, built into Windows 10 1803+ / macOS / Linux) for the Tomcat tar.gz.
  Same layout rules as LuceeExpress.java (lucee.express.layout=1):
    tar.gz deps -> extracted into the root without the top folder and without webapps/
    jar deps    -> lib/ext/<artifactId>-<version>[-<classifier>].jar
    lucee-express-<v>-template.zip -> extracted over the root, last
#>
param(
  [Parameter(Mandatory = $true, Position = 0)] [string] $Version,
  [Parameter(Mandatory = $true, Position = 1)] [string] $Target,
  [string[]] $Repos = $(if ($env:LUCEE_EXPRESS_REPOS) { $env:LUCEE_EXPRESS_REPOS -split '[,\s]+' } else { @('https://repo1.maven.org/maven2') }),
  [string] $Cache = $(if ($env:LUCEE_EXPRESS_CACHE) { $env:LUCEE_EXPRESS_CACHE } else { Join-Path (Join-Path $HOME '.m2') 'repository' }),
  [switch] $Force
)
$ErrorActionPreference = 'Stop'
$Repos = @($Repos | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })   # pwsh -File passes 'a','b' as one string
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:Downloaded = 0

function Get-Remote([string] $Url, [string] $Dest) {
  # returns $true on success, $false if the resource does not exist
  if ($Url.StartsWith('file:')) {
    $p = ([Uri] $Url).LocalPath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
    Copy-Item -LiteralPath $p -Destination $Dest -Force; return $true
  }
  try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -Headers @{ 'User-Agent' = 'lucee-express-assembler/1' }; return $true }
  catch {
    $code = $null; if ($_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
    if ($code -eq 404) { return $false }
    throw
  }
}

function Test-CachedFile([string] $File) {
  foreach ($a in @('SHA256', 'SHA1')) {
    $sum = "$File.$($a.ToLower())"
    if (Test-Path -LiteralPath $sum) {
      $want = ((Get-Content -LiteralPath $sum -Raw).Trim() -split '\s+')[0]
      return ((Get-FileHash -LiteralPath $File -Algorithm $a).Hash -ieq $want)
    }
  }
  return $true   # e.g. written by Maven itself
}

function Get-Artifact([string] $G, [string] $A, [string] $V, [string] $Type = 'jar', [string] $Classifier) {
  $file = "$A-$V" + $(if ($Classifier) { "-$Classifier" } else { '' }) + ".$Type"
  $rel = ($G -replace '\.', '/') + "/$A/$V/$file"
  $dest = Join-Path $Cache $rel
  $id = "$G`:$A`:$V`:$Type" + $(if ($Classifier) { ":$Classifier" } else { '' })
  if (Test-Path -LiteralPath $dest -PathType Leaf) {
    if (Test-CachedFile $dest) { Write-Host "  cache   $id"; return $dest }
    Remove-Item -LiteralPath $dest -Force
  }
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  foreach ($repo in $Repos) {
    $url = $repo.TrimEnd('/') + "/$rel"
    $alg = $null
    foreach ($a in @('SHA256', 'SHA1')) {
      if (Get-Remote "$url.$($a.ToLower())" "$dest.sum") { $alg = $a; break }
    }
    if (-not $alg) { continue }
    $want = ((Get-Content -LiteralPath "$dest.sum" -Raw).Trim() -split '\s+')[0].ToLower()
    Remove-Item -LiteralPath "$dest.sum" -Force
    if (-not (Get-Remote $url "$dest.part")) { throw "download failed: $url" }
    $have = (Get-FileHash -LiteralPath "$dest.part" -Algorithm $alg).Hash.ToLower()
    if ($have -ne $want) { Remove-Item -LiteralPath "$dest.part" -Force; throw "checksum mismatch for $url ($alg $have != $want)" }
    Set-Content -LiteralPath "$dest.$($alg.ToLower())" -Value $want -NoNewline
    Move-Item -LiteralPath "$dest.part" -Destination $dest -Force
    $size = (Get-Item -LiteralPath $dest).Length; $script:Downloaded += $size
    Write-Host ("  fetched $id ({0:N0} KB, $alg ok) from $repo" -f ($size / 1KB))
    return $dest
  }
  throw "$id not found in: $($Repos -join ', ')"
}

if (Test-Path -LiteralPath $Target) {
  if (-not $Force) { throw "target exists: $Target (use -Force)" }
  Remove-Item -LiteralPath $Target -Recurse -Force
}

# --- POM
[xml] $pom = Get-Content -LiteralPath (Get-Artifact 'org.lucee' 'lucee-express' $Version 'pom') -Raw
$ns = New-Object Xml.XmlNamespaceManager $pom.NameTable
$ns.AddNamespace('m', 'http://maven.apache.org/POM/4.0.0')
$props = @{}
foreach ($p in $pom.SelectNodes('/m:project/m:properties/*', $ns)) { $props[$p.LocalName] = $p.InnerText.Trim() }
if ($props['lucee.express.layout'] -and [int] $props['lucee.express.layout'] -gt 1) { throw "lucee-express layout $($props['lucee.express.layout']) is newer than this script supports (1)" }
function Expand-Props([string] $s) { if (-not $s) { return $s }; [regex]::Replace($s, '\$\{([^}]+)\}', { param($m) $props[$m.Groups[1].Value] }) }

# --- resolve all, then lay out in a temp dir next to the target
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($Target))
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$tmp = Join-Path $parent (".lucee-express." + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $jars = @()
  foreach ($d in $pom.SelectNodes('/m:project/m:dependencies/m:dependency', $ns)) {
    $opt = $d.SelectSingleNode('m:optional', $ns); $scope = $d.SelectSingleNode('m:scope', $ns)
    if (($opt -and $opt.InnerText -eq 'true') -or ($scope -and $scope.InnerText -in @('test', 'provided'))) { continue }
    $g = Expand-Props $d.SelectSingleNode('m:groupId', $ns).InnerText
    $a = Expand-Props $d.SelectSingleNode('m:artifactId', $ns).InnerText
    $v = Expand-Props $d.SelectSingleNode('m:version', $ns).InnerText
    $t = $d.SelectSingleNode('m:type', $ns); $t = if ($t) { Expand-Props $t.InnerText } else { 'jar' }
    $c = $d.SelectSingleNode('m:classifier', $ns); $c = if ($c) { Expand-Props $c.InnerText } else { $null }
    $file = Get-Artifact $g $a $v $t $c
    switch ($t) {
      { $_ -in @('tar.gz', 'tgz') } {
        & tar -xzf $file -C $tmp --strip-components=1 --exclude '*/webapps' --exclude '*/webapps/*'
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $file" }
      }
      'jar' { $jars += , @($file, ("$a-$v" + $(if ($c) { "-$c" } else { '' }) + '.jar')) }
      default { throw "unsupported dependency type $t ($g`:$a)" }
    }
  }
  $libExt = Join-Path (Join-Path $tmp 'lib') 'ext'
  New-Item -ItemType Directory -Force -Path $libExt | Out-Null
  foreach ($j in $jars) { Copy-Item -LiteralPath $j[0] -Destination (Join-Path $libExt $j[1]) }
  $template = Get-Artifact 'org.lucee' 'lucee-express' $Version 'zip' 'template'
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($template)
  try {
    foreach ($e in $zip.Entries) {
      $out = [IO.Path]::GetFullPath((Join-Path $tmp $e.FullName))
      if (-not $out.StartsWith([IO.Path]::GetFullPath($tmp))) { throw "zip entry outside target: $($e.FullName)" }
      if ($e.FullName.EndsWith('/')) { New-Item -ItemType Directory -Force -Path $out | Out-Null; continue }
      New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
      [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
    }
  } finally { $zip.Dispose() }
  if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Get-ChildItem -LiteralPath $tmp -Recurse -Filter '*.sh' | ForEach-Object { & chmod +x $_.FullName }
  }
  Move-Item -LiteralPath $tmp -Destination $Target
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
Write-Host ("Lucee Express $Version assembled in $Target ({0:N1} MB downloaded)" -f ($script:Downloaded / 1MB))

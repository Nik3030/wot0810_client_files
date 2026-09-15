<# : batch
@echo off
setlocal
rem ------------------------------------------------------------------
rem  wot0810: client patch sync. Put this file next to WorldOfTanks.exe.
rem    sync.bat           update patches
rem    sync.bat restore   put original client files back
rem ------------------------------------------------------------------
set "SYNC_SELF=%~f0"
set "SYNC_DIR=%~dp0"
set "SYNC_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:SYNC_SELF, [Text.Encoding]::UTF8))"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
#>

# Батник выше — только запуск; всё остальное PowerShell 5.1, что есть в любой
# Windows 10/11. Git не нужен: манифест и файлы берутся по HTTPS.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Откуда брать: корень репозитория раздачи в raw-виде. Подставляет
# ./run-server.sh client-release --repo=...
$Repo = 'https://raw.githubusercontent.com/Nik3030/wot0810_client_files/main'

$Client = $env:SYNC_DIR.TrimEnd('\')
$Mode = ([string]$env:SYNC_ARGS).Trim().ToLower()
$StateFile = Join-Path $Client 'wot0810_sync.txt'
$BackupDir = Join-Path $Client 'wot0810_backup'

function Say( $text ) { Write-Host "  $text" }
function Fail( $text ) {
	Write-Host "[x] $text" -ForegroundColor Red
	exit 1
}

function LocalPath( $rel ) { Join-Path $Client ( $rel -replace '/', '\' ) }
function BackupPath( $rel ) { Join-Path $BackupDir ( $rel -replace '/', '\' ) }
function FileHash( $path ) {
	( Get-FileHash -Algorithm SHA256 -LiteralPath $path ).Hash.ToLower()
}

# Что ставили в прошлый раз: по этому списку удаляется лишнее и делается
# откат. Чужие файлы в клиенте не трогаются никогда.
function ReadState {
	if ( Test-Path -LiteralPath $StateFile ) {
		return @( Get-Content -LiteralPath $StateFile | Where-Object { $_ -and -not $_.StartsWith( '#' ) } )
	}
	return @()
}

# Ванильный файл, который мы заменяем, сохраняется один раз: при первой
# замене. Файл, поставленный нами же, копией не считается.
function Backup( $rel, $installed ) {
	$local = LocalPath $rel
	$copy = BackupPath $rel
	if ( ( Test-Path -LiteralPath $local ) -and -not ( Test-Path -LiteralPath $copy ) -and ( $installed -notcontains $rel ) ) {
		New-Item -ItemType Directory -Force -Path ( Split-Path $copy ) | Out-Null
		Copy-Item -LiteralPath $local -Destination $copy
	}
}

# Вернуть оригинал или, если его не было, удалить наш файл.
function Revert( $rel ) {
	$local = LocalPath $rel
	$copy = BackupPath $rel
	if ( Test-Path -LiteralPath $copy ) {
		Copy-Item -LiteralPath $copy -Destination $local -Force
		Remove-Item -LiteralPath $copy
	} elseif ( Test-Path -LiteralPath $local ) {
		Remove-Item -LiteralPath $local
	}
}

# res обязан стоять в paths.xml выше пакетов, иначе деревья исследований из
# gui.pkg перекроют наши: движок отдаёт первый найденный файл. Строка только
# переставляется, остальной файл не трогается.
function FixPaths {
	$file = Join-Path $Client 'paths.xml'
	if ( -not ( Test-Path -LiteralPath $file ) ) { return }
	$lines = [Collections.Generic.List[string]]( [IO.File]::ReadAllLines( $file ) )
	$res = -1; $pkg = -1
	for ( $i = 0; $i -lt $lines.Count; $i++ ) {
		if ( $res -lt 0 -and $lines[ $i ] -match '<Path>\s*\./res\s*</Path>' ) { $res = $i }
		if ( $pkg -lt 0 -and $lines[ $i ] -match '<Path>\s*\./res/packages/' ) { $pkg = $i }
	}
	if ( $res -lt 0 -or $pkg -lt 0 -or $res -lt $pkg ) { return }
	$copy = BackupPath 'paths.xml'
	if ( -not ( Test-Path -LiteralPath $copy ) ) {
		New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
		Copy-Item -LiteralPath $file -Destination $copy
	}
	$line = $lines[ $res ]
	$lines.RemoveAt( $res )
	$lines.Insert( $pkg, $line )
	[IO.File]::WriteAllLines( $file, $lines )
	Say 'paths.xml: ./res поднят выше пакетов'
}

# --- проверки ------------------------------------------------------------

if ( -not ( Test-Path -LiteralPath ( Join-Path $Client 'WorldOfTanks.exe' ) ) ) {
	Fail "WorldOfTanks.exe не найден рядом с батником ($Client)"
}
$version = Join-Path $Client 'version.xml'
if ( -not ( Test-Path -LiteralPath $version ) -or -not ( Select-String -LiteralPath $version -Pattern 'v\.0\.8\.10' -Quiet ) ) {
	Fail 'нужен клиент World of Tanks 0.8.10'
}
if ( Get-Process -Name 'WorldOfTanks' -ErrorAction SilentlyContinue ) {
	Fail 'закройте игру: скрипты клиента подхватываются только при запуске'
}

$installed = ReadState

# --- откат ---------------------------------------------------------------

if ( $Mode -eq 'restore' ) {
	foreach ( $rel in $installed ) { Revert $rel }
	$paths = BackupPath 'paths.xml'
	if ( Test-Path -LiteralPath $paths ) {
		Copy-Item -LiteralPath $paths -Destination ( Join-Path $Client 'paths.xml' ) -Force
		Remove-Item -LiteralPath $paths
	}
	if ( Test-Path -LiteralPath $StateFile ) { Remove-Item -LiteralPath $StateFile }
	if ( Test-Path -LiteralPath $BackupDir ) { Remove-Item -LiteralPath $BackupDir -Recurse -Force }
	Say "клиент возвращён к оригиналу, файлов: $( $installed.Count )"
	exit 0
}

# --- синхронизация -------------------------------------------------------

if ( $Repo -like '__*' ) { Fail 'в батнике не задан адрес репозитория' }

Say 'читаю манифест'
try {
	$text = ( Invoke-WebRequest -UseBasicParsing -Uri "$Repo/manifest.txt?t=$( [DateTime]::UtcNow.Ticks )" ).Content
} catch {
	Fail "манифест не скачался: $( $_.Exception.Message )"
}
if ( $text -is [byte[]] ) { $text = [Text.Encoding]::UTF8.GetString( $text ) }

$release = '?'
$entries = @()
foreach ( $line in ( $text -split "`r?`n" ) ) {
	$line = $line.Trim()
	if ( -not $line -or $line.StartsWith( '#' ) ) { continue }
	$parts = $line -split '\s+', 3
	if ( $parts[ 0 ] -eq 'version' ) { $release = $parts[ 1 ]; continue }
	if ( $parts.Count -ne 3 -or $parts[ 2 ] -notmatch '^res/[A-Za-z0-9_./-]+$' -or $parts[ 2 ] -match '\.\.' ) {
		Fail "строка манифеста не читается: $line"
	}
	$entries += , @( $parts[ 0 ].ToLower(), [int64]$parts[ 1 ], $parts[ 2 ] )
}
if ( $entries.Count -eq 0 ) { Fail 'манифест пуст' }

$tmpDir = Join-Path $env:TEMP ( 'wot0810_sync_' + [Guid]::NewGuid().ToString( 'N' ) )
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$wanted = @()
$updated = 0
try {
	foreach ( $e in $entries ) {
		$hash, $size, $rel = $e
		$wanted += $rel
		$local = LocalPath $rel
		if ( ( Test-Path -LiteralPath $local ) -and ( FileHash $local ) -eq $hash ) { continue }

		$tmp = Join-Path $tmpDir ( [IO.Path]::GetFileName( $local ) )
		try {
			Invoke-WebRequest -UseBasicParsing -Uri "$Repo/files/$rel" -OutFile $tmp
		} catch {
			Fail "не скачался $rel : $( $_.Exception.Message )"
		}
		if ( ( Get-Item -LiteralPath $tmp ).Length -ne $size -or ( FileHash $tmp ) -ne $hash ) {
			Fail "$rel пришёл не тот (хеш не сошёлся). Подождите пару минут и повторите"
		}
		Backup $rel $installed
		New-Item -ItemType Directory -Force -Path ( Split-Path $local ) | Out-Null
		Move-Item -LiteralPath $tmp -Destination $local -Force
		Say "обновлён $rel"
		$updated++
	}
} finally {
	Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

$removed = 0
foreach ( $rel in $installed ) {
	if ( $wanted -notcontains $rel ) {
		Revert $rel
		Say "убран $rel"
		$removed++
	}
}

FixPaths

$state = @( "# wot0810 sync: version $release, $( Get-Date -Format 'yyyy-MM-dd HH:mm' )" ) + $wanted
[IO.File]::WriteAllLines( $StateFile, [string[]]$state )

Say "версия ${release}: обновлено $updated, убрано $removed, всего файлов $( $wanted.Count )"
exit 0

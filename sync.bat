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
where powershell >nul 2>&1
if errorlevel 1 (
	echo [x] PowerShell not found. Windows 10 or 11 is required.
	pause
	exit /b 1
)
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

# Подставляет ./run-server.sh client-release: корень репозитория раздачи в
# raw-виде и имя сервера из scripts_config.xml.
$Repo = 'https://raw.githubusercontent.com/Nik3030/wot0810_client_files/main'
$Server = 'CLASSIC_CORE'
if ( $Server -like '__*' ) { $Server = 'wot0810' }

function Say( $text ) { Write-Host "      $text" }
function Step( $n, $text ) { Write-Host ''; Write-Host " [$n/4] $text" -ForegroundColor Cyan }
function Item( $mark, $text, $color ) { Write-Host "      $mark $text" -ForegroundColor $color }
function Fail( $text, $hint ) {
	Write-Host ''
	Write-Host " [x] $text" -ForegroundColor Red
	if ( $hint ) { Write-Host "     $hint" -ForegroundColor Yellow }
	if ( $script:Touched ) {
		Write-Host ''
		Write-Host '     Клиент не испорчен: уже поставленные файлы записаны, батник можно' -ForegroundColor DarkGray
		Write-Host '     запустить ещё раз.' -ForegroundColor DarkGray
	}
	Write-Host ''
	if ( $script:lock ) {
		$script:lock.Dispose()
		Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
	}
	exit 1
}
$Touched = $false
$lock = $null

trap { Fail "непредвиденная ошибка: $( $_.Exception.Message )" 'Сообщите разработчику текст выше.' }

$Client = ( [string]$env:SYNC_DIR ).TrimEnd( '\' )
$Mode = ( [string]$env:SYNC_ARGS ).Trim().Trim( '"' ).ToLower()
$StateFile = Join-Path $Client 'wot0810_sync.txt'
$BackupDir = Join-Path $Client 'wot0810_backup'
$TmpDir = Join-Path $Client 'wot0810_sync_tmp'
$LockFile = Join-Path $Client 'wot0810_sync.lock'
$Tries = 3

try { $Host.UI.RawUI.WindowTitle = "$Server — обновление клиента" } catch { }

Write-Host ''
Write-Host ' ============================================================' -ForegroundColor DarkCyan
Write-Host "   $Server — правки клиента World of Tanks 0.8.10" -ForegroundColor White
Write-Host ' ============================================================' -ForegroundColor DarkCyan
if ( $Mode -eq 'restore' ) {
	Say 'Режим отката: наши файлы убираются, оригиналы клиента'
	Say 'возвращаются на место из папки wot0810_backup.'
} else {
	Say 'Батник скачивает правки клиента для сервера и заменяет только'
	Say 'изменившиеся файлы. Каждый файл сверяется по контрольной сумме.'
	Say 'Оригиналы сохраняются в папку wot0810_backup рядом с игрой.'
	Say 'Вернуть клиент к оригиналу: sync.bat restore'
}

function LocalPath( $rel ) { Join-Path $Client ( $rel -replace '/', '\' ) }
function BackupPath( $rel ) { Join-Path $BackupDir ( $rel -replace '/', '\' ) }
function FileHash( $path ) {
	( Get-FileHash -Algorithm SHA256 -LiteralPath $path ).Hash.ToLower()
}
function EnsureDir( $path ) {
	if ( -not ( Test-Path -LiteralPath $path ) ) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
}
function SizeText( $bytes ) {
	if ( $bytes -ge 1MB ) { return '{0:0.0} МБ' -f ( $bytes / 1MB ) }
	return '{0:0} КБ' -f [Math]::Max( 1, $bytes / 1KB )
}

# Список файлов, которые поставил батник. Пишется после каждого изменения,
# чтобы оборванный запуск не терял, что уже стоит. Чужие файлы клиента
# батник не трогает никогда.
function ReadState {
	$list = New-Object Collections.Generic.List[string]
	if ( Test-Path -LiteralPath $StateFile ) {
		foreach ( $line in [IO.File]::ReadAllLines( $StateFile ) ) {
			$line = $line.Trim()
			if ( $line -and -not $line.StartsWith( '#' ) -and -not $list.Contains( $line ) ) { $list.Add( $line ) }
		}
	}
	return , $list
}
function SaveState( $list, $note ) {
	$lines = @( "# wot0810 sync: $note, $( Get-Date -Format 'yyyy-MM-dd HH:mm' )" ) + @( $list )
	[IO.File]::WriteAllLines( $StateFile, [string[]]$lines )
}

# Файл клиента, который мы заменяем, сохраняется один раз: при первой замене.
# Звать только для файлов не из списка: поставленный нами оригиналом не считается.
function Backup( $rel ) {
	$local = LocalPath $rel
	$copy = BackupPath $rel
	if ( ( Test-Path -LiteralPath $local ) -and -not ( Test-Path -LiteralPath $copy ) ) {
		EnsureDir ( Split-Path $copy )
		Copy-Item -LiteralPath $local -Destination $copy
		return $true
	}
	return $false
}

# Вернуть оригинал ($true) или, если его не было, удалить наш файл ($false).
function Revert( $rel ) {
	$local = LocalPath $rel
	$copy = BackupPath $rel
	if ( Test-Path -LiteralPath $copy ) {
		EnsureDir ( Split-Path $local )
		Copy-Item -LiteralPath $copy -Destination $local -Force
		Remove-Item -LiteralPath $copy
		return $true
	}
	if ( Test-Path -LiteralPath $local ) { Remove-Item -LiteralPath $local }
	return $false
}

function Download( $url, $path ) {
	for ( $try = 1; ; $try++ ) {
		try {
			Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $url -OutFile $path
			return
		} catch {
			if ( $try -ge $Tries ) { throw }
			Write-Host "нет ответа, повтор через $( 3 * $try ) с ... " -NoNewline -ForegroundColor Yellow
			Start-Sleep -Seconds ( 3 * $try )
		}
	}
}
function NoCache { "t=$( [DateTime]::UtcNow.Ticks )" }

# res обязан стоять в paths.xml выше пакетов, иначе файлы из gui.pkg
# перекроют наши: движок отдаёт первый найденный. Строка только
# переставляется, остальной файл не трогается.
function FixPaths {
	$file = Join-Path $Client 'paths.xml'
	if ( -not ( Test-Path -LiteralPath $file ) ) {
		Item '!' 'paths.xml не найден — правки интерфейса могут не подхватиться' Yellow
		return
	}
	$lines = [Collections.Generic.List[string]]( [IO.File]::ReadAllLines( $file ) )
	$res = -1; $pkg = -1
	for ( $i = 0; $i -lt $lines.Count; $i++ ) {
		if ( $res -lt 0 -and $lines[ $i ] -match '<Path>\s*\./res\s*</Path>' ) { $res = $i }
		if ( $pkg -lt 0 -and $lines[ $i ] -match '<Path>\s*\./res/packages/' ) { $pkg = $i }
	}
	if ( $res -lt 0 -or $pkg -lt 0 -or $res -lt $pkg ) {
		Say 'paths.xml в порядке'
		return
	}
	[void]( Backup 'paths.xml' )
	$line = $lines[ $res ]
	$lines.RemoveAt( $res )
	$lines.Insert( $pkg, $line )
	[IO.File]::WriteAllLines( $file, $lines )
	Item '*' 'paths.xml: папка res поставлена выше архивов игры' Green
}

# --- проверки ------------------------------------------------------------

Step 1 'Проверка клиента'

if ( $PSVersionTable.PSVersion.Major -lt 5 ) {
	Fail "нужен PowerShell 5, здесь $( $PSVersionTable.PSVersion )" 'Батник работает на Windows 10 и 11.'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ( $Mode -ne '' -and $Mode -ne 'restore' ) {
	Fail "непонятный параметр «$Mode»" 'Запуск: sync.bat — обновить, sync.bat restore — вернуть оригинал.'
}
Say "папка игры: $Client"
if ( -not ( Test-Path -LiteralPath ( Join-Path $Client 'WorldOfTanks.exe' ) ) ) {
	Fail 'рядом с батником нет WorldOfTanks.exe' 'Положите sync.bat в папку игры, рядом с WorldOfTanks.exe.'
}
$version = Join-Path $Client 'version.xml'
if ( -not ( Test-Path -LiteralPath $version ) -or -not ( Select-String -LiteralPath $version -Pattern 'v\.0\.8\.10' -Quiet ) ) {
	Fail 'это не клиент World of Tanks 0.8.10' 'Нужна именно версия 0.8.10 (см. version.xml в папке игры).'
}
if ( -not ( Test-Path -LiteralPath ( Join-Path $Client 'res' ) ) ) {
	Fail 'в папке игры нет папки res' 'Клиент неполный — переустановите его.'
}
if ( Get-Process -Name 'WorldOfTanks' -ErrorAction SilentlyContinue ) {
	Fail 'игра запущена' 'Закройте World of Tanks и запустите батник снова.'
}
try {
	$probe = Join-Path $Client 'res\wot0810_write_test.tmp'
	[IO.File]::WriteAllText( $probe, 'ok' )
	Remove-Item -LiteralPath $probe
} catch {
	Fail 'нет прав на запись в папку игры' 'Запустите батник от имени администратора (правой кнопкой).'
}
try {
	$lock = [IO.File]::Open( $LockFile, 'OpenOrCreate', 'ReadWrite', 'None' )
} catch {
	Fail 'батник уже запущен в другом окне' 'Дождитесь, пока он закончит.'
}
Say 'клиент 0.8.10, игра закрыта, запись разрешена'

$state = ReadState

# --- откат ---------------------------------------------------------------

if ( $Mode -eq 'restore' ) {
	Step 2 'Поиск установленных правок'
	if ( $state.Count -eq 0 -and -not ( Test-Path -LiteralPath $BackupDir ) ) {
		Say 'правок не найдено, клиент уже в исходном виде'
	} else {
		Say "поставлено батником файлов: $( $state.Count )"
	}

	Step 3 'Возврат оригиналов'
	$count = 0
	$Touched = $true
	foreach ( $rel in @( $state ) ) {
		if ( Revert $rel ) { Item '<' "$rel — возвращён оригинал" Green } else { Item '-' "$rel — удалён" Gray }
		[void]$state.Remove( $rel )
		SaveState $state 'откат не завершён'
		$count++
	}
	# Оригиналы без записи в списке (paths.xml, следы оборванных запусков).
	if ( Test-Path -LiteralPath $BackupDir ) {
		$root = ( Get-Item -LiteralPath $BackupDir ).FullName.TrimEnd( '\' ) + '\'
		foreach ( $f in @( Get-ChildItem -LiteralPath $BackupDir -Recurse | Where-Object { -not $_.PSIsContainer } ) ) {
			$rel = $f.FullName.Substring( $root.Length ).Replace( '\', '/' )
			[void]( Revert $rel )
			Item '<' "$rel — возвращён оригинал" Green
			$count++
		}
		Remove-Item -LiteralPath $BackupDir -Recurse -Force
	}

	Step 4 'Завершение'
	Remove-Item -LiteralPath $StateFile -ErrorAction SilentlyContinue
	$lock.Dispose()
	Remove-Item -LiteralPath $LockFile -ErrorAction SilentlyContinue
	Write-Host ''
	Write-Host " Готово: клиент возвращён к оригиналу, файлов: $count" -ForegroundColor Green
	Write-Host '     Чтобы снова играть на сервере, запустите sync.bat.'
	Write-Host ''
	exit 0
}

# --- синхронизация -------------------------------------------------------

if ( $Repo -like '__*' ) { Fail 'в батнике не задан адрес репозитория' 'Скачайте батник заново из репозитория раздачи.' }

Step 2 'Загрузка списка файлов'
if ( Test-Path -LiteralPath $TmpDir ) { Remove-Item -LiteralPath $TmpDir -Recurse -Force }
EnsureDir $TmpDir
$manifest = Join-Path $TmpDir 'manifest.txt'
Write-Host '      связь с сервером раздачи ... ' -NoNewline
try {
	Download "$Repo/manifest.txt?$( NoCache )" $manifest
	Write-Host 'есть' -ForegroundColor Green
} catch {
	Fail "список файлов не скачался: $( $_.Exception.Message )" 'Проверьте интернет; если GitHub недоступен — попробуйте позже или через VPN.'
}

$release = $null
$entries = @()
$seen = @{}
foreach ( $line in [IO.File]::ReadAllLines( $manifest, [Text.Encoding]::UTF8 ) ) {
	$line = $line.Trim()
	if ( -not $line -or $line.StartsWith( '#' ) ) { continue }
	$parts = $line -split '\s+'
	if ( $parts[ 0 ] -eq 'version' -and $parts.Count -eq 2 ) { $release = $parts[ 1 ]; continue }
	if ( $parts.Count -ne 3 -or $parts[ 0 ] -notmatch '^[0-9a-fA-F]{64}$' -or $parts[ 1 ] -notmatch '^\d+$' `
			-or $parts[ 2 ] -notmatch '^res/[A-Za-z0-9_./-]+$' -or $parts[ 2 ] -match '\.\.|//' ) {
		Fail "список файлов повреждён, строка: $line" 'Повторите позже; если не проходит — сообщите разработчику.'
	}
	if ( $seen.ContainsKey( $parts[ 2 ] ) ) { Fail "список файлов повреждён: $( $parts[ 2 ] ) дважды" 'Сообщите разработчику.' }
	$seen[ $parts[ 2 ] ] = $true
	$entries += , @( $parts[ 0 ].ToLower(), [int64]$parts[ 1 ], $parts[ 2 ] )
}
if ( -not $release -or $entries.Count -eq 0 ) { Fail 'список файлов пуст или повреждён' 'Повторите позже.' }
Say "версия раздачи: $release, файлов: $( $entries.Count )"

Step 3 'Сверка и обновление файлов'
$updated = 0
$fresh = 0
foreach ( $e in $entries ) {
	$hash, $size, $rel = $e
	$local = LocalPath $rel
	if ( ( Test-Path -LiteralPath $local ) -and ( FileHash $local ) -eq $hash ) {
		$fresh++
		continue
	}

	# Качается рядом с игрой, чтобы замена была переименованием на том же диске.
	Write-Host "      + $rel ($( SizeText $size )) ... " -NoNewline
	$tmp = Join-Path $TmpDir ( [Guid]::NewGuid().ToString( 'N' ) )
	for ( $try = 1; ; $try++ ) {
		try {
			Download "$Repo/files/${rel}?$( NoCache )" $tmp
		} catch {
			Fail "не скачался $rel : $( $_.Exception.Message )" 'Проверьте интернет и запустите батник ещё раз.'
		}
		if ( ( Get-Item -LiteralPath $tmp ).Length -eq $size -and ( FileHash $tmp ) -eq $hash ) { break }
		if ( $try -ge $Tries ) {
			Fail "$rel пришёл не тот (контрольная сумма не сошлась)" 'Раздачу, скорее всего, только что обновили — повторите через пару минут.'
		}
		Write-Host "контрольная сумма не сошлась, повтор через $( 5 * $try ) с ... " -NoNewline -ForegroundColor Yellow
		Start-Sleep -Seconds ( 5 * $try )
	}

	$Touched = $true
	$saved = $false
	if ( -not $state.Contains( $rel ) ) {
		$saved = Backup $rel
		$state.Add( $rel )
		SaveState $state "установка $release не завершена"
	}
	EnsureDir ( Split-Path $local )
	Move-Item -LiteralPath $tmp -Destination $local -Force
	if ( $saved ) { Write-Host 'обновлён, оригинал сохранён' -ForegroundColor Green } else { Write-Host 'обновлён' -ForegroundColor Green }
	$updated++
}
if ( $fresh -gt 0 ) { Say "уже актуальны: $fresh" }

$removed = 0
foreach ( $rel in @( $state ) ) {
	if ( -not $seen.ContainsKey( $rel ) ) {
		if ( Revert $rel ) { Item '-' "$rel — больше не нужен, возвращён оригинал" Gray } else { Item '-' "$rel — больше не нужен, удалён" Gray }
		[void]$state.Remove( $rel )
		SaveState $state "установка $release не завершена"
		$removed++
	}
}

Step 4 'Завершение'
FixPaths
SaveState $state "version $release"
Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
$lock.Dispose()
Remove-Item -LiteralPath $LockFile -ErrorAction SilentlyContinue

Write-Host ''
if ( $updated -eq 0 -and $removed -eq 0 ) {
	Write-Host " Готово: клиент уже в актуальном состоянии (версия $release)." -ForegroundColor Green
} else {
	Write-Host " Готово: обновлено $updated, убрано $removed (версия $release)." -ForegroundColor Green
}
Write-Host "     Можно запускать игру и заходить на сервер $Server."
Write-Host ''
exit 0

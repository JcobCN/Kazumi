import 'dart:io';

import 'package:path/path.dart' as path;

/// PowerShell helper used to update a portable Windows installation after the
/// running application has exited. The helper is deliberately written to a
/// temporary directory and launched detached, so the application can release
/// its own executable and DLLs before they are replaced.
const String windowsPortableUpdateScript = r'''
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [int] $KazumiProcessId,

  [Parameter(Mandatory = $true)]
  [string] $ArchivePath,

  [Parameter(Mandatory = $true)]
  [string] $InstallDirectory,

  [Parameter(Mandatory = $true)]
  [string] $ExecutablePath,

  [Parameter(Mandatory = $true)]
  [string] $LogPath,

  [Parameter(Mandatory = $true)]
  [string] $CleanupDirectoryPath
)

$ErrorActionPreference = 'Stop'
$stagingDirectory = Join-Path $env:TEMP ('Kazumi-update-' + [guid]::NewGuid().ToString('N'))
$backupDirectory = $null
$oldDirectoryMoved = $false
$updateSucceeded = $false

function Write-UpdateLog([string] $message) {
  try {
    Add-Content -LiteralPath $LogPath -Value (('{0} {1}' -f (Get-Date -Format o), $message))
  } catch {
    # Logging must never prevent rollback or restart.
  }
}

function Remove-UpdateWorkspace {
  try {
    if (Test-Path -LiteralPath $CleanupDirectoryPath) {
      Remove-Item -LiteralPath $CleanupDirectoryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {
    # The temporary workspace can be removed by the OS later.
  }
}

try {
  Write-UpdateLog 'Updater started.'

  # Wait until the Flutter process has really exited and released its file
  # handles. The updater itself runs from %TEMP%, never from the app folder.
  $processDeadline = (Get-Date).AddSeconds(60)
  while ($null -ne (Get-Process -Id $KazumiProcessId -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $processDeadline) {
      throw 'Timed out waiting for the application to exit.'
    }
    Start-Sleep -Milliseconds 250
  }

  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw ('Update archive does not exist: ' + $ArchivePath)
  }

  New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $stagingDirectory -Force

  # Releases currently contain the Flutter bundle at the ZIP root. Accept a
  # single top-level directory as well, so older/customly packaged releases
  # remain updateable.
  $payloadDirectory = $stagingDirectory
  $payloadEntries = @(Get-ChildItem -LiteralPath $stagingDirectory -Force)
  if ($payloadEntries.Count -eq 1 -and $payloadEntries[0].PSIsContainer) {
    $payloadDirectory = $payloadEntries[0].FullName
  }

  $executableName = Split-Path -Leaf $ExecutablePath
  $newExecutablePath = Join-Path $payloadDirectory $executableName
  if (-not (Test-Path -LiteralPath $newExecutablePath -PathType Leaf)) {
    throw ('The update archive does not contain the application executable: ' + $executableName)
  }

  $installParent = Split-Path -Parent $InstallDirectory
  $installName = Split-Path -Leaf $InstallDirectory
  $backupDirectory = Join-Path $installParent ('.' + $installName + '.kazumi-update-backup-' + [guid]::NewGuid().ToString('N'))

  # Move the complete old bundle away first. This prevents stale DLLs/assets
  # from surviving an update and gives us a rollback point if copying fails.
  $moveError = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      Move-Item -LiteralPath $InstallDirectory -Destination $backupDirectory -ErrorAction Stop
      $moveError = $null
      break
    } catch {
      $moveError = $_
      Start-Sleep -Milliseconds 250
    }
  }
  if ($null -ne $moveError) {
    throw ('Unable to move the previous installation: ' + $moveError.Exception.Message)
  }
  $oldDirectoryMoved = $true
  New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null

  foreach ($entry in @(Get-ChildItem -LiteralPath $payloadDirectory -Force)) {
    $destination = Join-Path $InstallDirectory $entry.Name
    Copy-Item -LiteralPath $entry.FullName -Destination $destination -Recurse -Force
  }

  $installedExecutablePath = Join-Path $InstallDirectory $executableName
  if (-not (Test-Path -LiteralPath $installedExecutablePath -PathType Leaf)) {
    throw ('The application executable was not installed: ' + $installedExecutablePath)
  }

  # Start the new application before deleting the rollback copy. If process
  # creation fails, the catch block can still restore the previous bundle.
  $startedProcess = Start-Process -FilePath $installedExecutablePath -WorkingDirectory $InstallDirectory -PassThru
  Start-Sleep -Milliseconds 1000
  if ($startedProcess.HasExited) {
    throw ('The updated application exited immediately with code ' + $startedProcess.ExitCode)
  }
  Write-UpdateLog ('Updated application started with PID ' + $startedProcess.Id)
  $updateSucceeded = $true

  # Deleting the backup is best effort. A locked backup must not make a
  # successfully installed update look like a failed update.
  try {
    Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
  } catch {
    Write-UpdateLog ('Could not remove backup directory: ' + $_.Exception.Message)
  }

  Write-UpdateLog 'Update installed and application restarted.'
} catch {
  $errorMessage = $_.Exception.Message
  Write-UpdateLog ('Update failed: ' + $errorMessage)

  # Roll back only after the old bundle has been moved successfully. The new
  # directory contains only the partially copied update at this point.
  if ($oldDirectoryMoved -and -not $updateSucceeded) {
    try {
      if (Test-Path -LiteralPath $InstallDirectory) {
        Remove-Item -LiteralPath $InstallDirectory -Recurse -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $backupDirectory) {
        Move-Item -LiteralPath $backupDirectory -Destination $InstallDirectory
      }
      Write-UpdateLog 'Rollback completed.'
    } catch {
      Write-UpdateLog ('Rollback failed: ' + $_.Exception.Message)
    }
  }

  # Do not leave the user with a closed application when an update fails.
  if (-not $updateSucceeded) {
    try {
      if (Test-Path -LiteralPath $ExecutablePath -PathType Leaf) {
        Start-Process -FilePath $ExecutablePath -WorkingDirectory $InstallDirectory
      }
    } catch {
      Write-UpdateLog ('Could not restart the previous application: ' + $_.Exception.Message)
    }
  }
} finally {
  try {
    if (Test-Path -LiteralPath $stagingDirectory) {
      Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $ArchivePath) {
      Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
    }
  } catch {
    # Best-effort cleanup only.
  }

  # The script itself lives in the workspace. Move out before removing it so
  # Windows does not retain the workspace as the updater's current directory.
  try {
    Set-Location -LiteralPath $env:TEMP
  } catch {
    # Best-effort cleanup only.
  }
  Remove-UpdateWorkspace
}
''';

/// Starts a detached updater for a portable Windows bundle.
class WindowsPortableUpdater {
  const WindowsPortableUpdater();

  Future<void> schedule({
    required String archivePath,
    required String executablePath,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Windows portable updates are only supported on Windows.',
      );
    }

    final archive = File(archivePath);
    final executable = File(executablePath);
    if (!await archive.exists()) {
      throw FileSystemException('Update archive does not exist', archivePath);
    }
    if (!await executable.exists()) {
      throw FileSystemException(
          'Application executable does not exist', executablePath);
    }

    final workspace = await Directory.systemTemp.createTemp('kazumi-update-');
    final scriptPath = path.join(workspace.path, 'update.ps1');
    final logPath = path.join(workspace.path, 'update.log');
    await File(scriptPath).writeAsString(
      windowsPortableUpdateScript,
      flush: true,
    );

    final powershell = _powershellExecutable();
    await Process.start(
      powershell,
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptPath,
        '-KazumiProcessId',
        pid.toString(),
        '-ArchivePath',
        archive.path,
        '-InstallDirectory',
        executable.parent.path,
        '-ExecutablePath',
        executable.path,
        '-LogPath',
        logPath,
        '-CleanupDirectoryPath',
        workspace.path,
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: workspace.path,
    );
  }

  String _powershellExecutable() {
    final windowsDirectory = Platform.environment['WINDIR'];
    if (windowsDirectory != null && windowsDirectory.isNotEmpty) {
      final systemPowerShell = path.join(
        windowsDirectory,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      if (File(systemPowerShell).existsSync()) {
        return systemPowerShell;
      }
    }
    return 'powershell.exe';
  }
}

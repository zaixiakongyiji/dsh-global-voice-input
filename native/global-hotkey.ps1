param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$Hotkey
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class DshGlobalHotkey {
  [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")] public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
  [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG lpMsg);
  [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG lpMsg);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extra);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hWnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
  public static IntPtr FindMainWindow(int pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((hWnd, _) => { uint id; GetWindowThreadProcessId(hWnd, out id); if (id == pid && IsWindowVisible(hWnd)) { found = hWnd; return false; } return true; }, IntPtr.Zero);
    return found;
  }
}
'@

function Write-Event($value) {
  [Console]::WriteLine(($value | ConvertTo-Json -Compress))
  [Console]::Out.Flush()
}

$mods = 0
$key = 0
foreach ($part in $Hotkey.Split('+')) {
  switch ($part.ToLowerInvariant()) {
    'ctrl' { $mods = $mods -bor 0x0002 }
    'control' { $mods = $mods -bor 0x0002 }
    'alt' { $mods = $mods -bor 0x0001 }
    'shift' { $mods = $mods -bor 0x0004 }
    'win' { $mods = $mods -bor 0x0008 }
    'windows' { $mods = $mods -bor 0x0008 }
    'space' { $key = 0x20 }
    default {
      if ($part.Length -eq 1) { $key = [int][char]$part.ToUpperInvariant() }
      elseif ($part -match '^F([1-9]|1[0-2])$') { $key = 0x70 + ([int]$Matches[1]) - 1 }
    }
  }
}
if ($key -eq 0) { Write-Event @{ type = 'error'; code = 'invalid-hotkey'; message = "Unsupported hotkey: $Hotkey" }; exit 2 }

if (-not [DshGlobalHotkey]::RegisterHotKey([IntPtr]::Zero, 1, [uint32]$mods, [uint32]$key)) {
  Write-Event @{ type = 'error'; code = 'hotkey-conflict'; message = "Unable to register $Hotkey. It may already be in use." }
  exit 3
}

Write-Event @{ type = 'ready'; hotkey = $Hotkey; platform = 'windows' }
$msg = New-Object DshGlobalHotkey+MSG
try {
  while ([DshGlobalHotkey]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0) -gt 0) {
    if ($msg.message -eq 0x0312 -and $msg.wParam.ToUInt32() -eq 1) {
      $window = [DshGlobalHotkey]::FindMainWindow($ParentPid)
      if ($window -ne [IntPtr]::Zero) {
        [DshGlobalHotkey]::ShowWindowAsync($window, 9) | Out-Null
        [DshGlobalHotkey]::SetForegroundWindow($window) | Out-Null
      }
      Write-Event @{ type = 'trigger'; id = [guid]::NewGuid().ToString(); timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    }
    [DshGlobalHotkey]::TranslateMessage([ref]$msg) | Out-Null
    [DshGlobalHotkey]::DispatchMessage([ref]$msg) | Out-Null
  }
} finally {
  [DshGlobalHotkey]::UnregisterHotKey([IntPtr]::Zero, 1) | Out-Null
}

param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [switch]$SelfTest,
  [switch]$StateTest,
  [string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DshOverlayNative {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@
Add-Type @'
using System;
using System.Threading;
using System.Collections.Concurrent;
public static class DshOverlayInput {
  public static readonly ConcurrentQueue<string> Queue = new ConcurrentQueue<string>();
  public static volatile bool Closed;
  private static void Read() {
    try { string line; while ((line = Console.ReadLine()) != null) Queue.Enqueue(line); } catch { }
    finally { Closed = true; }
  }
  public static Thread Start() {
    var thread = new Thread(Read) { IsBackground = true };
    thread.Start();
    return thread;
  }
}
'@

function Write-Event($value) {
  [Console]::WriteLine(($value | ConvertTo-Json -Compress -Depth 4))
  [Console]::Out.Flush()
}

$queue = [DshOverlayInput]::Queue
$reader = [DshOverlayInput]::Start()

$window = [System.Windows.Window]::new()
$window.Title = 'DSH 全局语音输入'
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
$window.Topmost = $true
$window.ShowActivated = $false
$window.Width = 178
$window.Height = 48
$window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 24
$window.Top = [System.Windows.SystemParameters]::WorkArea.Bottom - $window.Height - 24
$script:hasCustomPosition = $false

$root = [System.Windows.Controls.Border]::new()
$root.CornerRadius = [System.Windows.CornerRadius]::new(24)
$root.Padding = [System.Windows.Thickness]::new(8, 5, 8, 5)
$root.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EE202124')
$root.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#553F4147')
$root.BorderThickness = [System.Windows.Thickness]::new(1)
$root.Effect = [System.Windows.Media.Effects.DropShadowEffect]@{ BlurRadius = 18; ShadowDepth = 3; Opacity = 0.35; Color = [System.Windows.Media.Colors]::Black }

$panel = [System.Windows.Controls.StackPanel]::new()
$panel.Orientation = [System.Windows.Controls.Orientation]::Vertical
$panel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
$panel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$root.Child = $panel
$window.Content = $root

$row = [System.Windows.Controls.StackPanel]::new()
$row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$row.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$panel.Children.Add($row) | Out-Null

function New-IconButton([string]$label, [string]$tooltip) {
  $button = [System.Windows.Controls.Button]::new()
  $button.Content = $label
  $button.ToolTip = $tooltip
  $button.Width = 42
  $button.Height = 34
  $button.Padding = [System.Windows.Thickness]::new(0)
  $button.Margin = [System.Windows.Thickness]::new(2, 0, 2, 0)
  $button.FontSize = 17
  $button.Foreground = [System.Windows.Media.Brushes]::White
  $button.Background = [System.Windows.Media.Brushes]::Transparent
  $button.BorderBrush = [System.Windows.Media.Brushes]::Transparent
  return $button
}

$iconText = [string][char]0x25B1
$iconIdle = [string][char]0x2301
$iconDown = [string][char]0x2304
$iconUp = [string][char]0x2303
$iconRecording = [string][char]0x25CF
$iconTranscribing = [string][char]0x21BB
$textButton = New-IconButton $iconText '打开文字输入'
$voiceButton = New-IconButton $iconIdle '开始语音输入'
$replyButton = New-IconButton $iconDown '展开回复'
$wavePanel = [System.Windows.Controls.StackPanel]::new()
$wavePanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$wavePanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$wavePanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$waveBars = @()
foreach ($index in 0..6) {
  $bar = [System.Windows.Shapes.Rectangle]::new()
  $bar.Width = 3
  $bar.Height = 6
  $bar.RadiusX = 1.5
  $bar.RadiusY = 1.5
  $bar.Margin = [System.Windows.Thickness]::new(2, 0, 2, 0)
  $bar.Fill = [System.Windows.Media.Brushes]::Tomato
  $wavePanel.Children.Add($bar) | Out-Null
  $waveBars += $bar
}
$row.Children.Add($textButton) | Out-Null
$row.Children.Add($voiceButton) | Out-Null
$row.Children.Add($replyButton) | Out-Null

$textBox = [System.Windows.Controls.TextBox]::new()
$textBox.Height = 30
$textBox.MinWidth = 260
$textBox.Margin = [System.Windows.Thickness]::new(2, 7, 2, 0)
$textBox.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
$textBox.Visibility = [System.Windows.Visibility]::Collapsed
$textBox.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF2B2D31')
$textBox.Foreground = [System.Windows.Media.Brushes]::White
$textBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#664F525A')
$panel.Children.Add($textBox) | Out-Null

$replyText = [System.Windows.Controls.TextBlock]::new()
$replyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
$replyText.MaxHeight = 150
$replyText.MinHeight = 28
$replyText.FontSize = 13
$replyText.Margin = [System.Windows.Thickness]::new(7, 7, 7, 3)
$replyText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFD6D8DE')
$replyText.Visibility = [System.Windows.Visibility]::Collapsed
$panel.Children.Add($replyText) | Out-Null

function Update-Layout {
  $inputVisible = $textBox.Visibility -eq [System.Windows.Visibility]::Visible
  $replyVisible = $replyText.Visibility -eq [System.Windows.Visibility]::Visible
  $targetWidth = if ($inputVisible -or $replyVisible) { 340 } else { 178 }
  $targetHeight = 48
  if ($inputVisible) { $targetHeight += 40 }
  if ($replyVisible) {
    # Do not reserve a fixed 160px block for a short or empty reply. WPF has
    # to measure the TextBlock after changing Visibility, otherwise the
    # expanded capsule becomes a large blank rectangle.
    $replyText.Measure([System.Windows.Size]::new(320, 150))
    $replyHeight = [Math]::Min(150, [Math]::Max(28, [double]$replyText.DesiredSize.Height))
    $targetHeight += [int][Math]::Ceiling($replyHeight) + 10
  }
  # Assigning the same WPF size on every microphone level/reply chunk causes
  # a topmost transparent window to repaint and visibly flash. Resize only
  # when the target dimensions actually changed.
  $sizeChanged = $window.Width -ne $targetWidth -or $window.Height -ne $targetHeight
  if ($sizeChanged) {
    $window.Width = $targetWidth
    $window.Height = $targetHeight
  }
  if ($sizeChanged -and -not $script:hasCustomPosition) {
    $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 24
    $window.Top = [System.Windows.SystemParameters]::WorkArea.Bottom - $window.Height - 24
  }
}

function Set-Expanded([bool]$expanded) {
  if ($script:expanded -eq $expanded) { return }
  $script:expanded = $expanded
  $replyText.Visibility = if ($expanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $replyButton.Content = if ($expanded) { $iconUp } else { $iconDown }
  $replyButton.ToolTip = if ($expanded) { '收起回复' } else { '展开回复' }
  if ($expanded -and [string]::IsNullOrWhiteSpace($replyText.Text)) { $replyText.Text = '等待当前 Session 回复…' }
  Update-Layout
}

function Set-TextOpen([bool]$open) {
  $textBox.Visibility = if ($open) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  Update-Layout
  if ($open) { $textBox.Focus() | Out-Null }
}

function Send-Action([string]$action, [string]$text) {
  $event = @{ type = 'action'; action = $action }
  if ($null -ne $text) { $event.text = $text }
  Write-Event $event
}

$textButton.Add_Click({ Set-TextOpen ($textBox.Visibility -ne [System.Windows.Visibility]::Visible); if ($textBox.Visibility -eq [System.Windows.Visibility]::Visible) { Send-Action 'openInput' $null } })
$voiceButton.Add_Click({
  if ($script:phase -eq 'idle' -or $script:phase -eq 'feedback') { Set-Visual-Phase 'requesting' } else { Set-Visual-Phase 'idle' }
  Send-Action 'voice' $null
})
$replyButton.Add_Click({ $open = $replyText.Visibility -ne [System.Windows.Visibility]::Visible; Set-Expanded $open; Send-Action 'toggleReply' $null })
$textBox.Add_KeyDown({ param($sender, $event); if ($event.Key -eq [System.Windows.Input.Key]::Enter) { $value = $textBox.Text.Trim(); if ($value.Length -gt 0) { Send-Action 'submitText' $value; $textBox.Clear(); Set-TextOpen $false }; $event.Handled = $true } elseif ($event.Key -eq [System.Windows.Input.Key]::Escape) { Set-TextOpen $false; $event.Handled = $true } })

$phase = 'idle'
$expanded = $false
$script:audioLevel = 0
$script:waveTick = 0

function Set-Visual-Phase([string]$nextPhase, [double]$level = 0) {
  $resolvedPhase = if ([string]::IsNullOrWhiteSpace($nextPhase)) { 'idle' } else { $nextPhase }
  $phaseChanged = $script:phase -ne $resolvedPhase
  $script:phase = $resolvedPhase
  $script:audioLevel = [Math]::Max(0, [Math]::Min(1, $level))
  if ($script:phase -eq 'recording') {
    if ($phaseChanged) { $voiceButton.Content = $wavePanel }
    $factors = @(0.35, 0.62, 1.0, 0.72, 1.0, 0.62, 0.35)
    for ($index = 0; $index -lt $waveBars.Count; $index++) {
      $waveBars[$index].Height = 6 + (22 * $script:audioLevel * $factors[$index])
    }
  } elseif ($phaseChanged) {
    $voiceButton.Content = switch ($script:phase) {
      'requesting' { [string][char]0x25CC }
      'transcribing' { $iconTranscribing }
      'feedback' { '!' }
      'waiting' { '…' }
      default { $iconIdle }
    }
  }
  if (-not $phaseChanged) { return }
  $voiceButton.Foreground = if ($script:phase -eq 'recording') { [System.Windows.Media.Brushes]::Tomato } elseif ($script:phase -in @('requesting', 'transcribing', 'feedback')) { [System.Windows.Media.Brushes]::Orange } else { [System.Windows.Media.Brushes]::White }
  $voiceButton.ToolTip = switch ($script:phase) {
    'recording' { '正在录音，点击取消' }
    'requesting' { '正在请求麦克风，点击取消' }
    'transcribing' { '正在转写，点击取消' }
    'feedback' { '查看语音输入状态' }
    'waiting' { '当前会话正在运行，语音输入已排队' }
    default { '开始语音输入' }
  }
}

# The capsule has no title bar. Drag any empty part of it to move the window;
# button and text-box clicks keep their normal actions.
$root.Add_MouseLeftButtonDown({ param($sender, $event)
  if ($event.OriginalSource -is [System.Windows.Controls.Button] -or $event.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
  $script:hasCustomPosition = $true
  $window.DragMove()
  $event.Handled = $true
})

$window.Add_Closed({
  if ($null -ne $timer) { $timer.Stop() }
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$window.Show() | Out-Null
Write-Event @{ type = 'overlay-ready' }

function Apply-State($value) {
  $nextPhase = if ($null -eq $value.phase) { 'idle' } else { [string]$value.phase }
  $level = if ($null -eq $value.level) { 0 } else { [double]$value.level }
  Set-Visual-Phase $nextPhase $level
  if ($value.message) { $voiceButton.ToolTip = [string]$value.message }
  $replyChanged = $false
  if ($null -ne $value.reply) {
    $nextReply = if ([string]::IsNullOrWhiteSpace([string]$value.reply)) { '等待当前 Session 回复…' } else { [string]$value.reply }
    if ($replyText.Text -ne $nextReply) {
      $replyText.Text = $nextReply
      $replyChanged = $true
    }
  }
  if ($null -ne $value.showReplyPreview) {
    $nextVisibility = if ($value.showReplyPreview) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    if ($replyButton.Visibility -ne $nextVisibility) { $replyButton.Visibility = $nextVisibility }
    if (-not $value.showReplyPreview) { Set-Expanded $false }
  }
  if ($null -ne $value.expanded -and $replyButton.Visibility -eq 'Visible') { Set-Expanded ([bool]$value.expanded) }
  # Streaming replies update the text frequently. Re-measure only when the
  # text really changed; Update-Layout itself avoids assigning equal sizes.
  if ($replyChanged -and $script:expanded) { Update-Layout }
}

if ($SelfTest) {
  if ($window.Content -ne $root -or $root.Child -ne $panel -or -not $window.Topmost) { throw 'Window content/topmost not connected' }
  $textButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
  if ($textBox.Visibility -ne 'Visible' -or $window.Width -lt 300) { throw 'Text input is clipped' }
  Set-TextOpen $false
  Apply-State ([pscustomobject]@{ phase = 'recording'; reply = '中文回复预览'; expanded = $true })
  if ($voiceButton.Foreground -ne [System.Windows.Media.Brushes]::Tomato -or $replyText.Visibility -ne 'Visible') { throw 'State not rendered' }
  if ($PreviewPath) {
    $window.UpdateLayout()
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $file = [System.IO.File]::Create($PreviewPath)
    try { $encoder.Save($file) } finally { $file.Dispose() }
  }
  Apply-State ([pscustomobject]@{ phase = 'idle'; showReplyPreview = $false })
  if ($replyText.Visibility -ne 'Collapsed') { throw 'Reply preview setting ignored' }
  Write-Event @{ type = 'self-test'; ok = $true }
  $window.Close()
  exit 0
}

if ($StateTest) {
  $script:heightChanges = [System.Collections.Generic.List[double]]::new()
  $heightDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.FrameworkElement]::HeightProperty, [System.Windows.Window])
  $heightDescriptor.AddValueChanged($window, [System.EventHandler]{ $script:heightChanges.Add($window.Height) })
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
  $line = $null
  while ($queue.TryDequeue([ref]$line)) {
    try {
      $value = $line | ConvertFrom-Json
      if ($value.type -eq 'state') {
        if ($StateTest) { $script:heightChanges.Clear() }
        Apply-State $value
        if ($StateTest) {
          $window.UpdateLayout()
          Write-Event @{
            type = 'state-applied'
            revision = $value.revision
            phase = $script:phase
            level = $script:audioLevel
            waveform = ($voiceButton.Content -eq $wavePanel)
            heights = @($waveBars | ForEach-Object { $_.Height })
            reply = $replyText.Text
            width = $window.Width
            height = $window.Height
            heightChanges = @($script:heightChanges.ToArray())
          }
        }
      }
    } catch { Write-Event @{ type = 'error'; message = $_.Exception.Message } }
  }
  if ($script:phase -eq 'recording') {
    # Keep the wave visibly alive between browser level reports. The amplitude
    # follows the latest microphone RMS value, with a small idle pulse so a
    # quiet speaker is still distinguishable from a stopped recording.
    $script:waveTick += 0.55
    $pulse = [Math]::Max(0.12, $script:audioLevel)
    $factors = @(0.35, 0.62, 1.0, 0.72, 1.0, 0.62, 0.35)
    for ($index = 0; $index -lt $waveBars.Count; $index++) {
      $wave = 0.55 + (0.45 * [Math]::Sin($script:waveTick + ($index * 0.9)))
      $waveBars[$index].Height = 6 + (22 * $pulse * $wave * $factors[$index])
    }
  }
  if ([DshOverlayInput]::Closed) { $window.Close(); return }
  try {
    $process = Get-Process -Id $ParentPid -ErrorAction Stop
    if ($process.HasExited) { $timer.Stop(); $window.Close() }
  } catch { $timer.Stop(); $window.Close() }
})
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()

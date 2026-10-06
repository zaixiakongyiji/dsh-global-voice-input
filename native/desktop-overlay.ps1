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
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extra);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr extra);
  public static void Focus(int[] processIds) {
    EnumWindows((hWnd, _) => {
      uint id; GetWindowThreadProcessId(hWnd, out id);
      if (Array.IndexOf(processIds, (int)id) < 0 || !IsWindowVisible(hWnd)) return true;
      ShowWindowAsync(hWnd, 9); SetForegroundWindow(hWnd); return false;
    }, IntPtr.Zero);
  }
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
$script:dshWindowPids = @()
if (-not $SelfTest -and -not $StateTest) {
  $ancestorId = $ParentPid
  for ($depth = 0; $depth -lt 6 -and $ancestorId -gt 0; $depth++) {
    $ancestor = Get-CimInstance Win32_Process -Filter "ProcessId = $ancestorId" -ErrorAction SilentlyContinue
    if ($null -eq $ancestor) { break }
    if ($ancestor.Name -eq 'DeepSeek Harness.exe') { $script:dshWindowPids += [int]$ancestorId }
    $ancestorId = [int]$ancestor.ParentProcessId
  }
}

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

$script:anchorBottom = [System.Windows.SystemParameters]::WorkArea.Bottom - 24

$root = [System.Windows.Controls.Border]::new()
$root.Background = [System.Windows.Media.Brushes]::Transparent

$panel = [System.Windows.Controls.StackPanel]::new()
$panel.Orientation = [System.Windows.Controls.Orientation]::Vertical
$panel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
$panel.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
$root.Child = $panel
$window.Content = $root

# 上方独立回复卡片列表容器（向上展开）
$replyArea = [System.Windows.Controls.StackPanel]::new()
$replyArea.Orientation = [System.Windows.Controls.Orientation]::Vertical
$replyArea.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
$replyArea.Visibility = [System.Windows.Visibility]::Collapsed
$replyScroller = [System.Windows.Controls.ScrollViewer]::new()
$replyScroller.Content = $replyArea
$replyScroller.MaxHeight = [Math]::Min(440, [System.Windows.SystemParameters]::WorkArea.Height - 120)
$replyScroller.VerticalScrollBarVisibility = 'Auto'
$replyScroller.HorizontalScrollBarVisibility = 'Disabled'
$replyScroller.Visibility = 'Collapsed'
$panel.Children.Add($replyScroller) | Out-Null

# 底部主控制胶囊（尺寸恒定药丸胶囊，绝不变形）
$capsuleBorder = [System.Windows.Controls.Border]::new()
$capsuleBorder.CornerRadius = [System.Windows.CornerRadius]::new(24)
$capsuleBorder.Padding = [System.Windows.Thickness]::new(8, 5, 8, 5)
$capsuleBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EE202124')
$capsuleBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#553F4147')
$capsuleBorder.BorderThickness = [System.Windows.Thickness]::new(1)
$capsuleBorder.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
$capsuleBorder.Effect = [System.Windows.Media.Effects.DropShadowEffect]@{ BlurRadius = 18; ShadowDepth = 3; Opacity = 0.35; Color = [System.Windows.Media.Colors]::Black }

$capsulePanel = [System.Windows.Controls.StackPanel]::new()
$capsulePanel.Orientation = [System.Windows.Controls.Orientation]::Vertical
$capsulePanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
$capsulePanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$capsuleBorder.Child = $capsulePanel
$panel.Children.Add($capsuleBorder) | Out-Null

$row = [System.Windows.Controls.StackPanel]::new()
$row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$row.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$capsulePanel.Children.Add($row) | Out-Null

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
  $button.Focusable = $false

  # The default WPF Button chrome draws a square pressed/focus rectangle over
  # the icon. Use a small rounded template so the selected state stays inside
  # the same circular capsule as the rest of the overlay.
  $template = [System.Windows.Controls.ControlTemplate]::new([System.Windows.Controls.Button])
  $chrome = [System.Windows.FrameworkElementFactory]::new([System.Windows.Controls.Border])
  $chrome.Name = 'chrome'
  $chrome.SetValue([System.Windows.FrameworkElement]::WidthProperty, [double]34)
  $chrome.SetValue([System.Windows.FrameworkElement]::HeightProperty, [double]34)
  $chrome.SetValue([System.Windows.Controls.Border]::CornerRadiusProperty, [System.Windows.CornerRadius]::new(18))
  $chrome.SetValue([System.Windows.Controls.Border]::BackgroundProperty, [System.Windows.Media.Brushes]::Transparent)
  $chrome.SetValue([System.Windows.Controls.Border]::BorderBrushProperty, [System.Windows.Media.Brushes]::Transparent)
  $chrome.SetValue([System.Windows.Controls.Border]::BorderThicknessProperty, [System.Windows.Thickness]::new(0))
  $content = [System.Windows.FrameworkElementFactory]::new([System.Windows.Controls.ContentPresenter])
  $content.SetValue([System.Windows.Controls.ContentPresenter]::HorizontalAlignmentProperty, [System.Windows.HorizontalAlignment]::Center)
  $content.SetValue([System.Windows.Controls.ContentPresenter]::VerticalAlignmentProperty, [System.Windows.VerticalAlignment]::Center)
  $chrome.AppendChild($content)
  $template.VisualTree = $chrome
  $pressed = [System.Windows.Trigger]::new()
  $pressed.Property = [System.Windows.Controls.Button]::IsPressedProperty
  $pressed.Value = $true
  $pressed.Setters.Add([System.Windows.Setter]::new(
    [System.Windows.Controls.Border]::BackgroundProperty,
    [System.Windows.Media.BrushConverter]::new().ConvertFromString('#553B82F6'),
    'chrome'))
  $hover = [System.Windows.Trigger]::new()
  $hover.Property = [System.Windows.Controls.Button]::IsMouseOverProperty
  $hover.Value = $true
  $hover.Setters.Add([System.Windows.Setter]::new(
    [System.Windows.Controls.Border]::BackgroundProperty,
    [System.Windows.Media.BrushConverter]::new().ConvertFromString('#333B82F6'),
    'chrome'))
  $template.Triggers.Add($hover)
  $template.Triggers.Add($pressed)
  $button.Template = $template
  return $button
}

$iconRecording = [string][char]0x25CF
$iconTranscribing = [string][char]0x21BB

function New-KeyboardVisual() {
  $canvas = [System.Windows.Controls.Canvas]::new()
  $canvas.Width = 20
  $canvas.Height = 20
  $canvas.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $canvas.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  # 键盘外框 (微圆角与半透白微填充)
  $rect = [System.Windows.Shapes.Rectangle]::new()
  $rect.Width = 15
  $rect.Height = 10
  $rect.RadiusX = 2.5
  $rect.RadiusY = 2.5
  $rect.Stroke = [System.Windows.Media.Brushes]::White
  $rect.StrokeThickness = 1.7
  $rect.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#25FFFFFF")
  [System.Windows.Controls.Canvas]::SetLeft($rect, 2.5)
  [System.Windows.Controls.Canvas]::SetTop($rect, 5)
  $canvas.Children.Add($rect) | Out-Null

  # 键盘内部按键与空格条
  $keys = [System.Windows.Shapes.Path]::new()
  $keys.Data = [System.Windows.Media.Geometry]::Parse("M 5.5,8 H 6.5 M 9.5,8 H 10.5 M 13.5,8 H 14.5 M 7,11.5 H 13")
  $keys.Stroke = [System.Windows.Media.Brushes]::White
  $keys.StrokeThickness = 1.5
  $keys.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $keys.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $canvas.Children.Add($keys) | Out-Null

  return $canvas
}

function New-ChevronVisual([bool]$up = $false) {
  $canvas = [System.Windows.Controls.Canvas]::new()
  $canvas.Width = 20
  $canvas.Height = 20
  $canvas.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $canvas.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $path = [System.Windows.Shapes.Path]::new()
  # 舒展圆角 V 形，开角约 100 度，端点和拐角均为圆润，不尖锐（与图二一致）
  $path.Data = if ($up) {
    [System.Windows.Media.Geometry]::Parse("M 5.5,12.5 L 10,8.5 L 14.5,12.5")
  } else {
    [System.Windows.Media.Geometry]::Parse("M 5.5,8.5 L 10,12.5 L 14.5,8.5")
  }
  $path.Stroke = [System.Windows.Media.Brushes]::White
  $path.StrokeThickness = 2.0
  $path.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $path.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $path.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
  $canvas.Children.Add($path) | Out-Null

  return $canvas
}

$chevronDown = New-ChevronVisual $false
$chevronUp = New-ChevronVisual $true

function New-MicVisual([System.Windows.Media.Brush]$strokeBrush, [System.Windows.Media.Brush]$fillBrush) {
  $canvas = [System.Windows.Controls.Canvas]::new()
  $canvas.Width = 20
  $canvas.Height = 20
  $canvas.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $canvas.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  # 拾音头 (Capsule) - 方案 C: 半透微填充
  $rect = [System.Windows.Shapes.Rectangle]::new()
  $rect.Width = 7
  $rect.Height = 11
  $rect.RadiusX = 3.5
  $rect.RadiusY = 3.5
  $rect.Stroke = $strokeBrush
  $rect.StrokeThickness = 1.7
  $rect.Fill = $fillBrush
  [System.Windows.Controls.Canvas]::SetLeft($rect, 6.5)
  [System.Windows.Controls.Canvas]::SetTop($rect, 1)
  $canvas.Children.Add($rect) | Out-Null

  # U形防震托架与支撑底座
  $path = [System.Windows.Shapes.Path]::new()
  $path.Data = [System.Windows.Media.Geometry]::Parse("M 4.5,7.5 A 5.5,5.5 0 0,0 15.5,7.5 M 10,13 L 10,17 M 6.5,17 L 13.5,17")
  $path.Stroke = $strokeBrush
  $path.StrokeThickness = 1.7
  $path.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $path.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $path.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
  $canvas.Children.Add($path) | Out-Null

  return $canvas
}

$micIdle = New-MicVisual ([System.Windows.Media.Brushes]::White) ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#40FFFFFF'))
$micRequesting = New-MicVisual ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF59E0B')) ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#40F59E0B'))

$micBreatheAnim = [System.Windows.Media.Animation.DoubleAnimation]::new()
$micBreatheAnim.From = 1.0
$micBreatheAnim.To = 0.35
$micBreatheAnim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(750))
$micBreatheAnim.AutoReverse = $true
$micBreatheAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

$textButton = New-IconButton '' '打开文字输入'
$textButton.Content = New-KeyboardVisual
$voiceButton = New-IconButton '' '开始语音输入'
$voiceButton.Content = $micIdle
$replyButton = New-IconButton '' '展开回复'
$replyButtonVisual = [System.Windows.Controls.Grid]::new()
$replyChevron = [System.Windows.Controls.ContentControl]::new()
$replyChevron.Content = $chevronDown
$replyButtonVisual.Children.Add($replyChevron) | Out-Null
$replyBadge = [System.Windows.Controls.TextBlock]::new()
$replyBadge.FontSize = 10
$replyBadge.Foreground = [System.Windows.Media.Brushes]::LightGreen
$replyBadge.HorizontalAlignment = 'Right'
$replyBadge.VerticalAlignment = 'Top'
$replyBadge.Margin = [System.Windows.Thickness]::new(20, -5, -9, 0)
$replyButtonVisual.Children.Add($replyBadge) | Out-Null
$replyButton.Content = $replyButtonVisual
$replyButton.Visibility = [System.Windows.Visibility]::Collapsed
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
$capsulePanel.Children.Add($textBox) | Out-Null

function New-StatusDot([bool]$inProgress = $true) {
  $grid = [System.Windows.Controls.Grid]::new()
  $grid.Width = 10
  $grid.Height = 10
  $grid.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
  $grid.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $dot = [System.Windows.Shapes.Ellipse]::new()
  $dot.Width = 8
  $dot.Height = 8
  $dot.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  if ($inProgress) {
    # 进行中：天蓝色圆点 + 呼吸闪烁
    $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF38BDF8')
    $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $anim.From = 1.0
    $anim.To = 0.25
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(650))
    $anim.AutoReverse = $true
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
  } else {
    # 已完成：绿色圆点，常亮
    $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF10B981')
  }

  $grid.Children.Add($dot) | Out-Null
  return $grid
}

# 默认回复卡片（包装现有单 reply 输出，保持与测试完全兼容）
$defaultReplyCard = [System.Windows.Controls.Border]::new()
$defaultReplyCard.Width = 340
$defaultReplyCard.CornerRadius = [System.Windows.CornerRadius]::new(18)
$defaultReplyCard.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
$defaultReplyCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$defaultReplyCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F2202124')
$defaultReplyCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#553F4147')
$defaultReplyCard.BorderThickness = [System.Windows.Thickness]::new(1)
$defaultReplyCard.Effect = [System.Windows.Media.Effects.DropShadowEffect]@{ BlurRadius = 14; ShadowDepth = 2; Opacity = 0.4; Color = [System.Windows.Media.Colors]::Black }

$defaultCardStack = [System.Windows.Controls.StackPanel]::new()
$defaultCardStack.Orientation = [System.Windows.Controls.Orientation]::Vertical

$defaultTitleRow = [System.Windows.Controls.DockPanel]::new()
$defaultTitleRow.LastChildFill = $true

$script:defaultStatusHost = [System.Windows.Controls.ContentControl]::new()
[System.Windows.Controls.DockPanel]::SetDock($script:defaultStatusHost, [System.Windows.Controls.Dock]::Right)
$defaultTitleRow.Children.Add($script:defaultStatusHost) | Out-Null

$script:defaultTitleText = [System.Windows.Controls.TextBlock]::new()
$script:defaultTitleText.Text = '当前会话'
$script:defaultTitleText.FontWeight = [System.Windows.FontWeights]::SemiBold
$script:defaultTitleText.FontSize = 13
$script:defaultTitleText.Foreground = [System.Windows.Media.Brushes]::White
$script:defaultTitleText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
$defaultTitleRow.Children.Add($script:defaultTitleText) | Out-Null
$defaultCardStack.Children.Add($defaultTitleRow) | Out-Null

$replyText = [System.Windows.Controls.TextBlock]::new()
$replyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
$replyText.MaxHeight = 150
$replyText.MinHeight = 22
$replyText.FontSize = 12
$replyText.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
$replyText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFD6D8DE')
$defaultCardStack.Children.Add($replyText) | Out-Null

$defaultReplyCard.Child = $defaultCardStack
$replyArea.Children.Add($defaultReplyCard) | Out-Null

function Update-Layout {
  $inputVisible = $textBox.Visibility -eq [System.Windows.Visibility]::Visible
  $replyVisible = $replyArea.Visibility -eq [System.Windows.Visibility]::Visible
  $targetWidth = if ($inputVisible -or $replyVisible) { 340 } else { 178 }
  $targetHeight = 48
  if ($inputVisible) { $targetHeight += 40 }
  if ($replyVisible) {
    # 测量上方卡片区域高度，保持向上生长
    $replyScroller.Measure([System.Windows.Size]::new(340, $replyScroller.MaxHeight))
    $replyHeight = [Math]::Max(36, [double]$replyScroller.DesiredSize.Height)
    $targetHeight += [int][Math]::Ceiling($replyHeight)
  }
  $sizeChanged = $window.Width -ne $targetWidth -or $window.Height -ne $targetHeight
  if ($sizeChanged) {
    $window.Width = $targetWidth
    $window.Height = $targetHeight
  }
  if ($sizeChanged -or -not $script:hasCustomPosition) {
    if (-not $script:hasCustomPosition) {
      $script:anchorBottom = [System.Windows.SystemParameters]::WorkArea.Bottom - 24
      $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $targetWidth - 24
    }
    $window.Top = $script:anchorBottom - $targetHeight
  }
}

function Set-Expanded([bool]$expanded) {
  if ($script:expanded -eq $expanded) { return }
  $script:expanded = $expanded
  $replyArea.Visibility = if ($expanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $replyScroller.Visibility = $replyArea.Visibility
  $replyText.Visibility = if ($expanded) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  Update-Reply-Button
  Update-Layout
}

function Set-TextOpen([bool]$open) {
  $textBox.Visibility = if ($open) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  Update-Layout
  if ($open) { $textBox.Focus() | Out-Null }
}

function Send-Action([string]$action, [string]$text, [string]$sessionId) {
  $event = @{ type = 'action'; action = $action }
  if ($null -ne $text) { $event.text = $text }
  if ($null -ne $sessionId) { $event.sessionId = $sessionId }
  Write-Event $event
  if ($action -eq 'openReply' -and $script:dshWindowPids.Count -gt 0) {
    [DshOverlayNative]::Focus([int[]]$script:dshWindowPids)
  }
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
$script:replyUnread = 0
$script:replyTotal = 0
$script:replyCardsSignature = ''
$script:replyCards = @()
$script:replyListMode = $false
$script:previewEnabled = $true
$script:cardsGeneration = 0

function Update-Reply-Button {
  $arrow = if ($script:expanded) { $chevronUp } else { $chevronDown }
  if ($replyChevron.Content -ne $arrow) { $replyChevron.Content = $arrow }
  $badgeText = if ($script:replyUnread -gt 99) { '99+' } elseif ($script:replyUnread -gt 0) { [string]$script:replyUnread } else { '' }
  if ($replyBadge.Text -ne $badgeText) { $replyBadge.Text = $badgeText }
  $replyButton.ToolTip = if ($script:replyUnread -gt 0) {
    "展开回复（$script:replyUnread 条新回复）"
  } elseif ($script:expanded) { '收起回复' } else { '展开回复' }
}

function Set-Visual-Phase([string]$nextPhase, [double]$level = 0) {
  $resolvedPhase = if ([string]::IsNullOrWhiteSpace($nextPhase)) { 'idle' } else { $nextPhase }
  $phaseChanged = $script:phase -ne $resolvedPhase
  $script:phase = $resolvedPhase
  $script:audioLevel = [Math]::Max([double]0, [Math]::Min([double]1, $level))
  if ($script:phase -eq 'recording') {
    if ($phaseChanged) {
      $micRequesting.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
      $voiceButton.Content = $wavePanel
    }
    $factors = @(0.35, 0.62, 1.0, 0.72, 1.0, 0.62, 0.35)
    for ($index = 0; $index -lt $waveBars.Count; $index++) {
      $waveBars[$index].Height = 6 + (22 * $script:audioLevel * $factors[$index])
    }
  } elseif ($phaseChanged) {
    if ($script:phase -eq 'requesting') {
      $voiceButton.Content = $micRequesting
      $micRequesting.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $micBreatheAnim)
    } else {
      $micRequesting.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
      $voiceButton.Content = switch ($script:phase) {
        'transcribing' { $iconTranscribing }
        'feedback' { '!' }
        'waiting' { '…' }
        default { $micIdle }
      }
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
$capsuleBorder.Add_MouseLeftButtonDown({ param($sender, $event)
  if ($event.OriginalSource -is [System.Windows.Controls.Button] -or $event.OriginalSource -is [System.Windows.Controls.TextBox] -or $event.OriginalSource -is [System.Windows.Controls.TextBlock]) { return }
  $script:hasCustomPosition = $true
  $window.DragMove()
  $script:anchorBottom = $window.Top + $window.Height
  $event.Handled = $true
})

$window.Add_Closed({
  if ($null -ne $timer) { $timer.Stop() }
  $micRequesting.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$window.Show() | Out-Null
Write-Event @{ type = 'overlay-ready' }

function Apply-State($value) {
  $nextPhase = if ($null -eq $value.phase) { $script:phase } else { [string]$value.phase }
  $level = if ($null -eq $value.level) { 0 } else { [double]$value.level }
  Set-Visual-Phase $nextPhase $level
  if ($value.message) { $voiceButton.ToolTip = [string]$value.message }
  $replyChanged = $false
  $hasList = $null -ne $value.PSObject.Properties['replies']
  if ($hasList) { $script:replyListMode = $true }
  elseif ($null -ne $value.reply) { $script:replyListMode = $false }
  $cardsSignature = if ($hasList) { ConvertTo-Json -InputObject @($value.replies) -Compress -Depth 5 } else { $script:replyCardsSignature }
  if ($hasList -and $cardsSignature -ne $script:replyCardsSignature) {
    $script:replyCardsSignature = $cardsSignature
    $script:replyCards = @($value.replies)
    $script:cardsGeneration++
    $replyChanged = $true
    $replyArea.Children.Clear()
    foreach ($item in $script:replyCards) {
      $itemTitle = if ([string]::IsNullOrWhiteSpace([string]$item.title)) { '会话任务' } else { [string]$item.title }
      $itemText = if ([string]::IsNullOrWhiteSpace([string]$item.text)) { '正在思考…' } else { [string]$item.text }
      $isDone = ($item.state -eq 'done' -or $item.state -eq 'completed')

      $card = [System.Windows.Controls.Border]::new()
      $card.Width = 340
      $card.CornerRadius = [System.Windows.CornerRadius]::new(18)
      $card.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
      $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
      $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F2202124')
      $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#553F4147')
      $card.BorderThickness = [System.Windows.Thickness]::new(1)
      $card.Effect = [System.Windows.Media.Effects.DropShadowEffect]@{ BlurRadius = 14; ShadowDepth = 2; Opacity = 0.4; Color = [System.Windows.Media.Colors]::Black }
      $card.Cursor = [System.Windows.Input.Cursors]::Hand
      $card.Add_MouseLeftButtonDown({ param($sender, $event) $event.Handled = $true }.GetNewClosure())
      $card.Add_MouseLeftButtonUp({ param($sender, $event)
        Send-Action 'openReply' $null ([string]$sender.Tag)
        $event.Handled = $true
      })
      $card.Tag = [string]$item.sessionId

      $stack = [System.Windows.Controls.StackPanel]::new()
      $stack.Orientation = [System.Windows.Controls.Orientation]::Vertical

      $tRow = [System.Windows.Controls.DockPanel]::new()
      $tRow.LastChildFill = $true

      $dot = New-StatusDot (-not $isDone)
      [System.Windows.Controls.DockPanel]::SetDock($dot, [System.Windows.Controls.Dock]::Right)
      $tRow.Children.Add($dot) | Out-Null

      $tb = [System.Windows.Controls.TextBlock]::new()
      $tb.Text = $itemTitle
      $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
      $tb.FontSize = 13
      $tb.Foreground = [System.Windows.Media.Brushes]::White
      $tb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
      $tRow.Children.Add($tb) | Out-Null
      $stack.Children.Add($tRow) | Out-Null

      $bb = [System.Windows.Controls.TextBlock]::new()
      $bb.Text = $itemText
      $bb.FontSize = 12
      $bb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
      $bb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFD6D8DE')
      $bb.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $bb.MaxHeight = 36
      $bb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
      $stack.Children.Add($bb) | Out-Null

      $card.Child = $stack
      $replyArea.Children.Add($card) | Out-Null
    }
    $replyText.Text = if ($script:replyCards.Count) { [string]$script:replyCards[-1].text } else { '' }
  } elseif (-not $hasList -and $null -ne $value.reply) {
    # Compatibility for older clients which send only one preview string.
    $nextReply = [string]$value.reply
    if ($replyText.Text -ne $nextReply -or -not $replyArea.Children.Contains($defaultReplyCard)) {
      $replyArea.Children.Clear()
      if (-not [string]::IsNullOrWhiteSpace($nextReply)) { $replyArea.Children.Add($defaultReplyCard) | Out-Null }
      $replyText.Text = $nextReply
      $replyChanged = $true
      $script:defaultStatusHost.Content = New-StatusDot $false
    }
  }
  if ($null -ne $value.showReplyPreview) { $script:previewEnabled = [bool]$value.showReplyPreview }
  $hasReplies = $replyArea.Children.Count -gt 0 -and ($script:replyListMode -or -not [string]::IsNullOrWhiteSpace($replyText.Text))
  $nextVisibility = if ($script:previewEnabled -and $hasReplies) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  if ($replyButton.Visibility -ne $nextVisibility) { $replyButton.Visibility = $nextVisibility }
  if ($null -ne $value.replyUnread) { $script:replyUnread = [Math]::Max(0, [int]$value.replyUnread) }
  Update-Reply-Button
  if ($replyButton.Visibility -ne 'Visible') { Set-Expanded $false }
  elseif ($null -ne $value.expanded) { Set-Expanded ([bool]$value.expanded) }
  # Streaming replies update the text frequently. Re-measure only when the
  # text really changed; Update-Layout itself avoids assigning equal sizes.
  if ($replyChanged -and $script:expanded) { Update-Layout }
}

if ($SelfTest) {
  if ($window.Content -ne $root -or $root.Child -ne $panel -or -not $window.Topmost) { throw 'Window content/topmost not connected' }
  $textButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
  if ($textBox.Visibility -ne 'Visible' -or $window.Width -lt 300) { throw 'Text input is clipped' }
  Set-TextOpen $false
  Apply-State ([pscustomobject]@{ phase = 'recording'; reply = '中文回复预览'; replyCount = 1; replies = @([pscustomobject]@{ sessionId = 'self-test'; text = '中文回复预览'; title = '测试会话'; state = 'done' }); replyUnread = 1; showReplyPreview = $true; expanded = $true })
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

# Process incoming states ahead of continuous render/animation work. The
# default Background priority can starve while an expanded preview animates.
$timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Normal)
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
            cardCount = $replyArea.Children.Count
            cardsGeneration = $script:cardsGeneration
            replyVisible = ($replyArea.Visibility -eq 'Visible')
            replyButtonVisible = ($replyButton.Visibility -eq 'Visible')
            replyUnread = $script:replyUnread
          }
        }
      } elseif ($StateTest -and $value.type -eq 'test-click-reply') {
        $card = $replyArea.Children[[int]$value.index]
        $click = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $click.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        $card.RaiseEvent($click)
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

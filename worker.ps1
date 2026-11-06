$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::InputEncoding=New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DesktopNative {
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb,IntPtr p);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h,uint cmd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint message,UIntPtr wParam,IntPtr lParam,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flags);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
 public struct RECT { public int Left,Top,Right,Bottom; }
 public struct POINT { public int X,Y; public POINT(int x,int y){X=x;Y=y;} }
 public static string Title(IntPtr h){var s=new StringBuilder(4096);GetWindowText(h,s,s.Capacity);return s.ToString();}
 public static string Class(IntPtr h){var s=new StringBuilder(512);GetClassName(h,s,s.Capacity);return s.ToString();}
 public static IntPtr[] Windows(){var list=new List<IntPtr>();EnumWindows((h,p)=>{list.Add(h);return true;},IntPtr.Zero);return list.ToArray();}
}
'@
try{[DesktopNative]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))|Out-Null}catch{}
function Hash([string]$value){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Scrub([string]$text){return [regex]::Replace($text,'(?i)([?&][A-Za-z0-9_]+)=([^&\s"<>]+)','$1=[redacted]')}
function WindowInfo([IntPtr]$handle){
 if(-not [DesktopNative]::IsWindow($handle)){throw 'Window no longer exists; list windows again.'}
 [uint32]$targetPid=0;[DesktopNative]::GetWindowThreadProcessId($handle,[ref]$targetPid)|Out-Null
 $process=Get-Process -Id $targetPid -ErrorAction Stop
 $start=$process.StartTime.ToUniversalTime().ToString('o');$title=[DesktopNative]::Title($handle);$class=[DesktopNative]::Class($handle)
 $rect=New-Object DesktopNative+RECT;[DesktopNative]::GetWindowRect($handle,[ref]$rect)|Out-Null
 return [ordered]@{hwnd=$handle.ToInt64().ToString();pid=[int]$targetPid;process=$process.ProcessName;session=$process.SessionId;process_started_utc=$start;process_start_filetime=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();title_sha256=(Hash $title);title=(Scrub $title);class_name=$class;visible=[DesktopNative]::IsWindowVisible($handle);owner_hwnd=[DesktopNative]::GetWindow($handle,4).ToInt64().ToString();minimized=[DesktopNative]::IsIconic($handle);bounds=@{x=$rect.Left;y=$rect.Top;width=$rect.Right-$rect.Left;height=$rect.Bottom-$rect.Top};window_key=(Hash ($handle.ToInt64().ToString()+'|'+$targetPid+'|'+$start+'|'+$class+'|'+$title))}
}
function GuardWindow($request){
 $handle=[IntPtr]::new([long]$request.hwnd);$info=WindowInfo $handle
 if([string]::IsNullOrWhiteSpace($request.window_key) -or $request.window_key -cne $info.window_key){throw 'Window identity changed or window_key missing; list/inspect again. No action performed.'}
 if($info.session -ne (Get-Process -Id $PID).SessionId){throw 'Target is not in this interactive desktop session.'}
 return $handle
}
function ElementInfo($element,[string]$rootKey,[int]$depth){
 $c=$element.Current;$runtime=($element.GetRuntimeId()-join '.');$name=if($c.IsPassword){'[password control]'}else{Scrub $c.Name}
 $patterns=@($element.GetSupportedPatterns()|ForEach-Object {$_.ProgrammaticName -replace 'PatternIdentifiers.Pattern$',''})
 return [ordered]@{element_key=(Hash ($rootKey+'|'+$runtime+'|'+$c.Name+'|'+$c.ControlType.ProgrammaticName));runtime_id=$runtime;name=$name;automation_id=$c.AutomationId;control_type=$c.ControlType.ProgrammaticName;class_name=$c.ClassName;pid=$c.ProcessId;enabled=$c.IsEnabled;offscreen=$c.IsOffscreen;is_password=$c.IsPassword;depth=$depth;bounds=@{x=$c.BoundingRectangle.X;y=$c.BoundingRectangle.Y;width=$c.BoundingRectangle.Width;height=$c.BoundingRectangle.Height};patterns=$patterns}
}
function Walk($root,[string]$rootKey,[int]$maxNodes,[int]$maxDepth,[string]$findKey=''){
 $queue=New-Object 'System.Collections.Generic.Queue[object]';$queue.Enqueue(@($root,0));$rows=New-Object 'System.Collections.Generic.List[object]';$walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
 $deadline=[DateTime]::UtcNow.AddSeconds(10)
 while($queue.Count -gt 0 -and $rows.Count -lt $maxNodes){
  if([DateTime]::UtcNow -gt $deadline){break}
  $pair=$queue.Dequeue();$element=$pair[0];$depth=[int]$pair[1]
  try{$info=ElementInfo $element $rootKey $depth}catch{continue}
  if($findKey -and $info.element_key -ceq $findKey){return $element}
  $rows.Add($info)
  if($depth -ge $maxDepth){continue}
  try{$child=$walker.GetFirstChild($element);while($null -ne $child){$queue.Enqueue(@($child,($depth+1)));$child=$walker.GetNextSibling($child)}}catch{}
 }
 if($findKey){throw 'Element identity not found within bounded current tree. Inspect again; no action performed.'}
 return [ordered]@{elements=$rows.ToArray();truncated=($queue.Count -gt 0);nodes=$rows.Count;max_depth=$maxDepth}
}
function Pattern($element,$id){$p=$null;if(-not $element.TryGetCurrentPattern($id,[ref]$p)){throw 'Required UI Automation pattern is unavailable; no fallback action performed.'};return $p}
function FocusTarget([IntPtr]$handle){
 if([DesktopNative]::IsIconic($handle)){[DesktopNative]::ShowWindow($handle,9)|Out-Null}
 [DesktopNative]::SetForegroundWindow($handle)|Out-Null
 [UIntPtr]$reply=[UIntPtr]::Zero
 if([DesktopNative]::SendMessageTimeout($handle,0,[UIntPtr]::Zero,[IntPtr]::Zero,2,2000,[ref]$reply) -eq [IntPtr]::Zero){throw 'Target did not acknowledge activation within the bounded timeout; input refused.'}
 if([DesktopNative]::GetForegroundWindow() -ne $handle){throw 'Could not verify target foreground; keyboard/pointer action refused.'}
}
try{
 $request=([Console]::In.ReadToEnd()|ConvertFrom-Json);$command=[string]$request.command
 if($command -eq 'capture_screen'){
  if(-not [IO.Path]::IsPathRooted([string]$request.output_path)){throw 'Use an absolute screenshot path.'}
  $path=[IO.Path]::GetFullPath([string]$request.output_path)
  if([IO.Path]::GetExtension($path) -ine '.png' -or (Test-Path -LiteralPath $path)){throw 'Use a fresh absolute PNG path.'}
  $screens=[Windows.Forms.Screen]::AllScreens;$index=if($null -ne $request.monitor_index){[int]$request.monitor_index}else{0}
  if($index -eq -1){$bounds=[Windows.Forms.SystemInformation]::VirtualScreen}elseif($index -ge 0 -and $index -lt $screens.Count){$bounds=$screens[$index].Bounds}else{throw 'Invalid monitor_index; use0..monitor_count-1 or-1 for all displays.'}
  if($bounds.Width -gt 12000 -or $bounds.Height -gt 12000){throw 'Capture exceeds bounded desktop dimensions.'}
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
  $bitmap=New-Object Drawing.Bitmap($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
  try{$graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
  $cursor=New-Object DesktopNative+POINT;[DesktopNative]::GetCursorPos([ref]$cursor)|Out-Null
  $result=@{path=$path;method='CopyFromScreen';coordinate_space='DPI-aware physical virtual-desktop pixels';bounds=@{x=$bounds.X;y=$bounds.Y;width=$bounds.Width;height=$bounds.Height};cursor=@{x=$cursor.X;y=$cursor.Y};monitor_count=$screens.Count;monitor_index=$index}
 }elseif($command -eq 'list_windows'){
  $session=(Get-Process -Id $PID).SessionId;$rows=@()
  foreach($handle in [DesktopNative]::Windows()){
   if(-not [DesktopNative]::IsWindowVisible($handle)){continue}
   try{$info=WindowInfo $handle;if($info.session -ne $session){continue};if($request.process -and $info.process -ine $request.process){continue};if($request.title_contains -and $info.title.IndexOf([string]$request.title_contains,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue};$rows += $info}catch{}
  }
  $result=@{windows=$rows;interactive_session=$session;foreground_hwnd=[DesktopNative]::GetForegroundWindow().ToInt64().ToString()}
 }else{
  $handle=GuardWindow $request;$window=WindowInfo $handle
  if($command -eq 'guard'){$result=$window
  }elseif($command -eq 'inspect'){
   $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
   $maxNodes=if($request.max_nodes){[int]$request.max_nodes}else{350};$maxDepth=if($request.max_depth){[int]$request.max_depth}else{12}
   if($maxNodes -lt 1 -or $maxNodes -gt 2500 -or $maxDepth -lt 0 -or $maxDepth -gt 30){throw 'Inspection bounds out of range'}
   $result=Walk $root $window.window_key $maxNodes $maxDepth
   $result.window=$window
  }elseif($command -eq 'screenshot'){
   if(-not [IO.Path]::IsPathRooted([string]$request.output_path)){throw 'Use an absolute screenshot path.'}
   $path=[IO.Path]::GetFullPath([string]$request.output_path)
   if([IO.Path]::GetExtension($path) -ine '.png'){throw 'Screenshot output must be an absolute PNG path.'}
   if(Test-Path -LiteralPath $path){throw 'Screenshot path already exists; choose a fresh path.'}
   $rect=$window.bounds;if($rect.width -le 0 -or $rect.height -le 0 -or $rect.width -gt 12000 -or $rect.height -gt 12000){throw 'Invalid window screenshot dimensions'}
   [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
   $bitmap=New-Object Drawing.Bitmap($rect.width,$rect.height);$graphics=[Drawing.Graphics]::FromImage($bitmap);$dc=$graphics.GetHdc()
   try{$captured=[DesktopNative]::PrintWindow($handle,$dc,2)}finally{$graphics.ReleaseHdc($dc);$graphics.Dispose()}
   try{if(-not $captured){throw 'PrintWindow did not capture this window; no whole-desktop fallback used.'};$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
   $result=@{window=$window;path=$path;method='PrintWindow PW_RENDERFULLCONTENT';pixel_content_requires_visual_check=$true}
  }elseif($command -eq 'act'){
   $action=[string]$request.action;$element=$null
   if($action -in @('invoke','set_value','toggle','expand','collapse','select','click','hover')){
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if(-not $request.element_key){throw 'element_key from a fresh inspection is required'}
    $element=Walk $root $window.window_key 2500 30 $request.element_key
    if(-not $element.Current.IsEnabled -or $element.Current.IsOffscreen){throw 'Target control is disabled or offscreen; action refused.'}
   }
   switch($action){
    'invoke' {(Pattern $element ([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()}
    'set_value' {if($element.Current.IsPassword){throw 'Password controls are excluded; use the normal user credential handoff.'};$p=Pattern $element ([System.Windows.Automation.ValuePattern]::Pattern);if($p.Current.IsReadOnly){throw 'Control is readonly'};$p.SetValue([string]$request.value)}
    'toggle' {(Pattern $element ([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()}
    'expand' {(Pattern $element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()}
    'collapse' {(Pattern $element ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Collapse()}
    'select' {(Pattern $element ([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()}
    'close' {$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle);(Pattern $root ([System.Windows.Automation.WindowPattern]::Pattern)).Close()}
    'focus' {FocusTarget $handle}
    'key' {
     $keys=@{Escape='{ESC}';Enter='{ENTER}';Tab='{TAB}';ShiftTab='+{TAB}';AltF4='%{F4}';Space=' ';Up='{UP}';Down='{DOWN}';Left='{LEFT}';Right='{RIGHT}';PageDown='{PGDN}';PageUp='{PGUP}';Home='{HOME}';End='{END}'}
     if(-not $keys.ContainsKey([string]$request.key)){throw 'Unsupported key; arbitrary command/hotkey strings are not accepted'}
     FocusTarget $handle;[System.Windows.Forms.SendKeys]::SendWait($keys[[string]$request.key])
    }
    {$_ -in @('click','hover','click_point','hover_point')} {
     FocusTarget $handle
     if($element){$r=$element.Current.BoundingRectangle;$x=[int]($r.X+$r.Width/2);$y=[int]($r.Y+$r.Height/2)}else{if($request.PSObject.Properties.Name -notcontains 'x' -or $request.PSObject.Properties.Name -notcontains 'y'){throw 'Point input requires both x and y.'};$x=[int]$window.bounds.x+[int]$request.x;$y=[int]$window.bounds.y+[int]$request.y}
     if($x -lt $window.bounds.x -or $y -lt $window.bounds.y -or $x -ge ($window.bounds.x+$window.bounds.width) -or $y -ge ($window.bounds.y+$window.bounds.height)){throw 'Pointer target outside scoped window'}
     [DesktopNative]::SetCursorPos($x,$y)|Out-Null
     [Threading.Thread]::Sleep(120)
     $actual=New-Object DesktopNative+POINT;[DesktopNative]::GetCursorPos([ref]$actual)|Out-Null
     if([Math]::Abs($actual.X-$x) -gt 3 -or [Math]::Abs($actual.Y-$y) -gt 3){throw 'Cursor changed before input; action refused.'}
     $hit=[DesktopNative]::WindowFromPoint($actual);$top=[DesktopNative]::GetAncestor($hit,2)
     if($top -ne $handle){throw 'Pointer point is covered by another window; action refused.'}
     if($action -in @('click','click_point')){[DesktopNative]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[DesktopNative]::mouse_event(4,0,0,0,[UIntPtr]::Zero)}
    }
    default {throw 'Unknown action'}
   }
   $result=@{action=$action;window_hwnd=$window.hwnd;window_exists_after=[DesktopNative]::IsWindow($handle);note='Action returned. Inspect the resulting window/UI state before deciding whether the workflow succeeded.'}
   if($action -in @('click_point','hover_point')){$cursor=New-Object DesktopNative+POINT;[DesktopNative]::GetCursorPos([ref]$cursor)|Out-Null;$result.cursor_after=@{x=$cursor.X;y=$cursor.Y}}
  }else{throw 'Unknown command'}
 }
 [Console]::WriteLine((@{ok=$true;result=$result;time_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 18 -Compress))
}catch{
 [Console]::WriteLine((@{ok=$false;error=$_.Exception.Message;time_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 5 -Compress))
 exit 1
}

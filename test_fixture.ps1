$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @'
using System;
using System.Drawing;
using System.Windows.Forms;
public static class SyntheticDesktopFixture {
 [STAThread] public static void Run(){
  Application.EnableVisualStyles();
  var form=new Form {Text="Codex UI Bridge Synthetic Test",Size=new Size(540,310),StartPosition=FormStartPosition.CenterScreen};
  form.Controls.Add(new Label {Text="Synthetic local UI test. No application data or external action.",Location=new Point(20,20),Size=new Size(485,25)});
  form.Controls.Add(new TextBox {Name="DemoInput",AccessibleName="Synthetic text input",Location=new Point(20,58),Size=new Size(300,25)});
  form.Controls.Add(new TextBox {Name="DemoPassword",AccessibleName="Synthetic password input",UseSystemPasswordChar=true,Location=new Point(20,95),Size=new Size(300,25)});
  var open=new Button {Name="OpenModal",Text="Open synthetic dialog",Location=new Point(20,142),Size=new Size(210,34)};
  open.Click+=delegate {
   using(var dialog=new Form {Text="Synthetic popup - no external action",Size=new Size(430,170),StartPosition=FormStartPosition.CenterParent,MinimizeBox=false,MaximizeBox=false}){
    dialog.Controls.Add(new Label {Text="This is a disposable synthetic modal dialog.",Location=new Point(18,18),Size=new Size(380,30)});
    var dismiss=new Button {Name="DismissSynthetic",Text="Dismiss synthetic popup",Location=new Point(90,68),Size=new Size(235,32),DialogResult=DialogResult.Cancel};
    dialog.CancelButton=dismiss;dialog.Controls.Add(dismiss);dialog.ShowDialog(form);
   }
  };form.Controls.Add(open);
  var second=new Button {Name="OpenSecondary",Text="Open second window",Location=new Point(250,142),Size=new Size(210,34)};
  second.Click+=delegate {new Form {Text="Synthetic secondary test window",Size=new Size(340,180)}.Show(form);};form.Controls.Add(second);
  form.Controls.Add(new CheckBox {Name="DemoToggle",Text="Synthetic checkbox",Location=new Point(20,198),Size=new Size(220,28)});
  Application.Run(form);form.Dispose();
 }
}
'@
[SyntheticDesktopFixture]::Run()

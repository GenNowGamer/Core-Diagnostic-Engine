using System;
using System.Reflection;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;

namespace ToolkitGUI.Views
{
    public partial class StartupSplashWindow : Window
    {
        private readonly DispatcherTimer _dismissTimer;

        public StartupSplashWindow()
        {
            InitializeComponent();
            VersionText.Text = $"Version {GetAppVersion()}";

            _dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            _dismissTimer.Tick += (_, _) => Dismiss();
            _dismissTimer.Start();
        }

        private void Splash_MouseDown(object sender, MouseButtonEventArgs e) => Dismiss();

        private void Dismiss()
        {
            _dismissTimer.Stop();
            Close();
        }

        private static string GetAppVersion()
        {
            var asmVersion = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(asmVersion))
            {
                var plusIndex = asmVersion.IndexOf('+');
                return plusIndex > 0 ? asmVersion[..plusIndex] : asmVersion;
            }

            return Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "1.0.0";
        }
    }
}

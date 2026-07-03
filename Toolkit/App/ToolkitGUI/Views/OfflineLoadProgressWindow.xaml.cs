using System;
using System.Windows;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class OfflineLoadProgressWindow : Window
    {
        public OfflineLoadProgressWindow()
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
        }

        public void UpdateStep(string message)
        {
            StepText.Text = message;
        }

        public void UpdateProgress(int percent)
        {
            var bounded = Math.Max(0, Math.Min(100, percent));
            LoadingProgressBar.Value = bounded;
        }
    }
}

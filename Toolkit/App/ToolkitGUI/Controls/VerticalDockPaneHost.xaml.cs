using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Services;

namespace ToolkitGUI.Controls
{
    public partial class VerticalDockPaneHost : UserControl
    {
        public static readonly DependencyProperty PrimaryTitleProperty =
            DependencyProperty.Register(nameof(PrimaryTitle), typeof(string), typeof(VerticalDockPaneHost),
                new PropertyMetadata("Primary", OnChromeChanged));

        public static readonly DependencyProperty SecondaryTitleProperty =
            DependencyProperty.Register(nameof(SecondaryTitle), typeof(string), typeof(VerticalDockPaneHost),
                new PropertyMetadata("Details", OnChromeChanged));

        public static readonly DependencyProperty PrimaryPaneProperty =
            DependencyProperty.Register(nameof(PrimaryPane), typeof(object), typeof(VerticalDockPaneHost),
                new PropertyMetadata(null));

        public static readonly DependencyProperty SecondaryPaneProperty =
            DependencyProperty.Register(nameof(SecondaryPane), typeof(object), typeof(VerticalDockPaneHost),
                new PropertyMetadata(null));

        public string PrimaryTitle
        {
            get => (string)GetValue(PrimaryTitleProperty);
            set => SetValue(PrimaryTitleProperty, value);
        }

        public string SecondaryTitle
        {
            get => (string)GetValue(SecondaryTitleProperty);
            set => SetValue(SecondaryTitleProperty, value);
        }

        public object? PrimaryPane
        {
            get => GetValue(PrimaryPaneProperty);
            set => SetValue(PrimaryPaneProperty, value);
        }

        public object? SecondaryPane
        {
            get => GetValue(SecondaryPaneProperty);
            set => SetValue(SecondaryPaneProperty, value);
        }

        public VerticalDockPaneHost()
        {
            InitializeComponent();
            Loaded += (_, _) =>
            {
                ApplyTitles();
                DockLayoutService.ApplyEnvironmentPreset(WorkbenchDock);
            };
        }

        private static void OnChromeChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is VerticalDockPaneHost host && host.IsLoaded)
                host.ApplyTitles();
        }

        private void ApplyTitles()
        {
            if (PrimaryDocument != null)
                PrimaryDocument.Title = PrimaryTitle;

            if (SecondaryAnchorable != null)
                SecondaryAnchorable.Title = SecondaryTitle;
        }
    }
}

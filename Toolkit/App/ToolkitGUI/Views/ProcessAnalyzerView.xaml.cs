using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class ProcessAnalyzerView : UserControl
    {
        private readonly ProcessAnalyzerViewModel _vm;

        public ProcessAnalyzerView()
        {
            InitializeComponent();
            _vm = new ProcessAnalyzerViewModel();
            DataContext = _vm;
            Loaded += OnLoaded;
            Unloaded += (_, _) => _vm.StopAutoRefresh();
        }

        private async void OnLoaded(object sender, RoutedEventArgs e)
        {
            ApplyPendingNavigationContext();
            await _vm.LoadAsync();
            _vm.StartAutoRefresh();
        }

        public void ApplyPendingNavigationContext()
        {
            var context = NavigationService.ConsumePendingContext();
            if (!string.IsNullOrWhiteSpace(context))
                _vm.ApplyNavigationContext(context);
        }

        private void KillSelected_Click(object sender, RoutedEventArgs e)
        {
            if (ProcessGrid.SelectedItem is ProcessEntry entry)
                _vm.KillCommand.Execute(entry);
            else if (ProcessTree.SelectedItem is ProcessTreeNode node && node.Entry != null)
                _vm.KillCommand.Execute(node.Entry);
        }

        private void ProcessTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
        {
            if (e.NewValue is ProcessTreeNode node)
                _vm.SelectedProcess = node.Entry;
        }
    }
}

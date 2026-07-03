using System.Windows;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class ChuResultsView : WorkflowViewBase
    {
        public ChuResultsView() => InitializeComponent();

        private void RefreshBtn_Click(object sender, RoutedEventArgs e)
        {
            if (DataContext is ChuResultsViewModel vm)
                vm.RefreshResults();
        }

        private void OpenDiagRepair_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not System.Windows.Controls.Button { Tag: string context } || string.IsNullOrWhiteSpace(context))
                return;

            NavigationService.Request("DiagAndRepair", context);
        }
    }
}

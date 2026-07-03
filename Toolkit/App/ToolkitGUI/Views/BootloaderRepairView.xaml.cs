using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class BootloaderRepairView : WorkflowViewBase
    {
        public BootloaderRepairView()
        {
            InitializeComponent();
            Loaded += OnLoaded;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            if (Vm?.IsWinPeAvailable == true && Vm.RefreshCommand.CanExecute(null))
                Vm.RefreshCommand.Execute(null);
        }

        private DiskBootRepairViewModel? Vm => DataContext as DiskBootRepairViewModel;

        private void DiskMap_PartitionSelected(object sender, RoutedEventArgs e)
        {
            if (e.OriginalSource is not FrameworkElement fe || Vm == null)
                return;

            if (fe.DataContext is CdePartitionModel part)
            {
                Vm.SelectedPartition = part;
                return;
            }

            if (e.OriginalSource is CdePartitionModel direct)
                Vm.SelectedPartition = direct;
        }

        private void BackupFile_CheckedChanged(object sender, RoutedEventArgs e)
        {
            Vm?.NotifyBackupSelectionChanged();
        }
    }
}

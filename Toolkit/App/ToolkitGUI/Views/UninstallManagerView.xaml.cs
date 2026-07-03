using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class UninstallManagerView : UserControl
    {
        private UninstallManagerViewModel _vm;

        public UninstallManagerView()
        {
            InitializeComponent();
            _vm = new UninstallManagerViewModel();
            DataContext = _vm;
            Loaded += async (_, _) => await _vm.LoadAsync();
        }

        private void Uninstall_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is InstalledProgram prog)
                _vm.UninstallCommand.Execute(prog);
        }

        private void ForceRemove_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is InstalledProgram prog)
                _vm.ForceRemoveCommand.Execute(prog);
        }
    }
}

using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class FastFixesView : WorkflowViewBase
    {
        private FastFixesViewModel _vm;

        public FastFixesView()
        {
            InitializeComponent();
            _vm = new FastFixesViewModel();
            DataContext = _vm;
            Loaded += async (_, _) => await _vm.LoadFixesAsync();
        }

        private void Category_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is string cat)
                _vm.SelectedCategory = cat;
        }

        private void Apply_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is FastFix fix)
                _vm.ApplyFixCommand.Execute(fix);
        }
    }
}

using System.Windows.Controls;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class SmartAnalyzerView : UserControl
    {
        private readonly SmartAnalyzerViewModel _vm;

        public SmartAnalyzerView()
        {
            InitializeComponent();
            _vm = new SmartAnalyzerViewModel();
            DataContext = _vm;
            Loaded += async (_, _) => await _vm.ScanAsync();
        }
    }
}

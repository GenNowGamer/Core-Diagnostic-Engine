using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class TempFileCleanerView : WorkflowViewBase
    {
        public TempFileCleanerView()
        {
            InitializeComponent();
            DataContext = new TempFileCleanerViewModel();
        }
    }
}
